(() => {
    "use strict";
    const snapshot = JSON.parse(document.getElementById("pricing-data").textContent);
    const hours = snapshot.hoursPerMonth;
    const specs = new Map(snapshot.specs.map(spec => [spec.key, spec]));
    const excluded = "Excludes backup, networking, tax, support, HA/DR replicas and usage-based IO charges. This is not a quote or a deployment-availability check.";
    const money = value => new Intl.NumberFormat("en-US", { style: "currency", currency: snapshot.currency }).format(value);

    function meter(predicate, region, type = "Consumption", term = "") {
        const candidates = snapshot.items.filter(item =>
            predicate(item) && item.type === type &&
            (!region || item.armRegionName === region) &&
            (!term || item.reservationTerm === term) &&
            Number(item.tierMinimumUnits) === 0 &&
            Date.parse(item.effectiveStartDate) <= Date.parse(snapshot.generatedUtc));
        const latest = new Map();
        for (const item of candidates) {
            const key = [item.meterId, item.skuName, item.reservationTerm].join("|");
            const previous = latest.get(key);
            if (!previous || Date.parse(item.effectiveStartDate) > Date.parse(previous.effectiveStartDate)) latest.set(key, item);
        }
        const values = [...latest.values()];
        if (!values.length) throw new Error("No matching " + type + " meter" + (term ? " (" + term + ")" : "") + " in the embedded snapshot.");
        const signatures = new Set(values.map(item => JSON.stringify([item.retailPrice, item.unitOfMeasure, item.savingsPlan])));
        if (signatures.size !== 1) throw new Error("Ambiguous retail meters; no price was guessed.");
        const result = values[0];
        if (!Number.isFinite(result.retailPrice) || result.retailPrice < 0) throw new Error("Invalid retail meter price.");
        return result;
    }

    function monthly(item, quantity = 1, term = "") {
        if (!(quantity > 0)) throw new Error("A positive billing quantity is required.");
        if (term) {
            if (item.unitOfMeasure !== "1 Hour") throw new Error("Unsupported reservation billing unit: " + item.unitOfMeasure);
            return item.retailPrice * quantity / (term === "1 Year" ? 12 : 36);
        }
        if (item.unitOfMeasure === "1 Hour") return item.retailPrice * quantity * hours;
        if (["1 GB/Month", "1/Month", "1 Disk/Month"].includes(item.unitOfMeasure)) return item.retailPrice * quantity;
        throw new Error("Unsupported billing unit: " + item.unitOfMeasure);
    }

    function estimate(spec, options) {
        const components = [];
        const notes = [...spec.notes];
        const add = (label, amount, source) => {
            if (!Number.isFinite(amount) || amount < 0) throw new Error("Invalid component price.");
            components.push({ label, amount, meter: source.meterId, product: source.productName });
        };
        try {
            if (spec.error) throw new Error(spec.error);
            if (!options.region) throw new Error("Select an Azure region.");
            if (snapshot.skipped) throw new Error("Pricing was skipped. Regenerate the summary without -SkipPricing.");
            if (spec.needsHardware && !options.assumeGen5) throw new Error("Hardware is unspecified. Confirm Standard-series (Gen5) below the region selector, or use a recommendation with explicit hardware.");
            const term = options.plan === "ri1" ? "1 Year" : options.plan === "ri3" ? "3 Years" : "";
            if (spec.target === "AzureSqlVirtualMachine") {
                if (options.plan === "dbsp1") throw new Error("The database savings plan does not apply to SQL Server on Azure VMs. Choose PAYG or a reservation.");
                const os = spec.os || "Windows";
                if (!spec.os) {
                    const assumption = "VM OS unspecified; Windows Server assumed, including Windows Server licensing.";
                    if (!notes.includes(assumption)) notes.push(assumption);
                }
                const vmSkuNames = [spec.armSku.toLowerCase(), spec.armSku.replace(/^Standard_/i, "").replace(/_/g, " ").toLowerCase()];
                const exactVm = item => String(item.armSkuName || "").toLowerCase() === spec.armSku.toLowerCase() &&
                    vmSkuNames.includes(item.skuName.toLowerCase());
                const linux = item => exactVm(item) && !item.productName.endsWith(" Windows");
                const windows = item => exactVm(item) && item.productName.endsWith(" Windows");
                const base = meter(linux, options.region);
                if (term) {
                    const reserved = meter(linux, options.region, "Reservation", term);
                    add("VM compute (" + term + " RI, amortized)", monthly(reserved, 1, term), reserved);
                    if (os === "Windows") {
                        const win = meter(windows, options.region);
                        add("Windows Server license (not covered by SQL Hybrid Benefit)", monthly(win) - monthly(base), win);
                    }
                } else {
                    const compute = os === "Windows" ? meter(windows, options.region) : base;
                    add("VM compute" + (os === "Windows" ? " and Windows Server license" : ""), monthly(compute), compute);
                }
                if (!options.ahb) {
                    const edition = spec.edition;
                    if (!edition) throw new Error(spec.editionError || "SQL edition is missing from the recommendation and source assessment.");
                    const licenseSku = spec.cores <= 4 ? "1-4 vCPU VM" : spec.cores + " vCPU VM";
                    const sql = meter(item => item.productName.toLowerCase() === ("SQL Server " + edition).toLowerCase() &&
                        item.skuName === licenseSku, "");
                    add("SQL Server " + edition + " license", monthly(sql), sql);
                }
                if (!spec.disks.length) notes.push("No managed-disk SKUs were specified; all VM storage is excluded.");
                for (const disk of spec.disks) {
                    if (!disk.redundancy) { notes.push(disk.sku + " redundancy unspecified; this disk is excluded."); continue; }
                    try {
                        const storage = meter(item => item.skuName === disk.sku + " " + disk.redundancy &&
                            item.meterName === disk.sku + " " + disk.redundancy + " Disk", options.region);
                        add(disk.count + " x " + disk.sku + " " + disk.redundancy + " disk", monthly(storage, disk.count), storage);
                    } catch (error) { notes.push("Disk storage excluded: " + error.message); }
                }
            } else {
                const computeMatch = item => item.productName === spec.computeProduct && item.meterName === "vCore" && item.skuName === "vCore";
                const perCoreMatch = item => item.productName === spec.computeProduct && item.meterName === "vCore" && item.skuName === "1 vCore";
                let compute;
                if (term) {
                    compute = meter(computeMatch, options.region, "Reservation", term);
                    add("Compute (" + term + " RI, amortized)", monthly(compute, spec.cores, term), compute);
                } else {
                    const hasVcore = snapshot.items.some(item => computeMatch(item) && item.armRegionName === options.region && item.type === "Consumption");
                    compute = meter(hasVcore ? computeMatch : perCoreMatch, options.region);
                    if (options.plan === "dbsp1") {
                        const plans = (compute.savingsPlan || []).filter(plan => plan.term === "1 Year");
                        if (plans.length !== 1 || !Number.isFinite(plans[0].retailPrice) || plans[0].retailPrice < 0) throw new Error("No unambiguous 1-year database savings-plan rate for this compute meter.");
                        add("Compute (1-year database savings plan)", plans[0].retailPrice * spec.cores * hours, compute);
                    } else {
                        add("Compute (PAYG)", monthly(compute, spec.cores), compute);
                    }
                }
                if (!options.ahb) {
                    const sql = meter(item => item.productName === spec.licenseProduct && item.skuName === "vCore" && item.unitOfMeasure === "1 Hour", "Global");
                    add("SQL license (not discounted by RI or database savings plan)", monthly(sql, spec.cores), sql);
                }
                if (spec.storageGb === null || spec.storageGb <= 0) {
                    notes.push("No positive storage quantity was specified; storage is excluded.");
                } else {
                    try {
                        const storage = meter(item => item.productName === spec.storageProduct && item.meterName === spec.storageMeter, options.region);
                        add(spec.storageGb + " GB recommended storage", monthly(storage, spec.storageGb), storage);
                    } catch (error) { notes.push("Storage excluded: " + error.message); }
                }
            }
            if (options.ahb) notes.push("SQL license charge waived: assumes sufficient eligible SQL Server licenses with Software Assurance or subscription rights. Windows Server licensing is not waived.");
            if (spec.needsHardware) notes.push("Standard-series (Gen5) hardware explicitly selected for an unspecified recommendation.");
            return { amount: components.reduce((sum, item) => sum + item.amount, 0), components, notes, error: "" };
        } catch (error) {
            return { amount: null, components: [], notes, error: error.message };
        }
    }

    const regionSelect = document.getElementById("pricing-region");
    const planSelect = document.getElementById("pricing-plan");
    const ahb = document.getElementById("pricing-ahb");
    const assumeGen5 = document.getElementById("pricing-gen5");
    const status = document.getElementById("pricing-status");
    const regionNames = new Map();
    for (const item of snapshot.items) {
        if (item.armRegionName && !["global", "us gov"].includes(item.armRegionName.toLowerCase()) &&
            !/^(usgov|usdod|china)/i.test(item.armRegionName) && item.unitOfMeasure === "1 Hour" &&
            item.type === "Consumption" && item.serviceName !== "Virtual Machines Licenses") {
            regionNames.set(item.armRegionName, item.location || item.armRegionName);
        }
    }
    for (const [value, label] of [...regionNames].sort((a, b) => a[1].localeCompare(b[1]))) {
        const option = document.createElement("option");
        option.value = value;
        option.textContent = label + " (" + value + ")";
        regionSelect.append(option);
    }
    document.getElementById("pricing-gen5-field").hidden = !snapshot.specs.some(spec => spec.needsHardware);
    const baseStatus = snapshot.skipped ? "Pricing snapshot skipped. Regenerate without -SkipPricing to enable estimates." :
        "USD retail pricing snapshot: " + new Date(snapshot.generatedUtc).toLocaleString() + ". " +
        regionNames.size + " regions. " + hours + " hours/month. " +
        (snapshot.errors.length ? snapshot.errors.length + " pricing queries failed; affected costs may be unavailable. " : "") +
        "Select a region to estimate. " + excluded;
    status.textContent = baseStatus;
    if (!snapshot.skipped && regionNames.size === 0) status.textContent += " No regional compute rates were found. Verify the recommendations, -PricingRegion values and any generation warnings.";
    regionSelect.disabled = regionNames.size === 0;

    function render() {
        let priced = 0;
        let unavailable = 0;
        for (const cell of document.querySelectorAll("[data-pricing-key]")) {
            cell.replaceChildren();
            if (!regionSelect.value) continue;
            const spec = specs.get(cell.dataset.pricingKey);
            const result = spec ? estimate(spec, {
                region: regionSelect.value, plan: planSelect.value, ahb: ahb.checked,
                assumeGen5: assumeGen5.checked
            }) : { amount: null, error: "No SKU recommendation.", notes: [], components: [] };
            const value = document.createElement("span");
            value.className = result.error ? "cost-unavailable" : "cost-value";
            value.textContent = result.error ? "Unavailable" : money(result.amount);
            cell.append(value);
            if (!result.error) {
                const scope = document.createElement("small");
                scope.className = "cost-scope";
                scope.textContent = "Subtotal; exclusions apply";
                cell.append(scope);
            }
            if (result.error) unavailable++; else priced++;
            const details = document.createElement("details");
            const summary = document.createElement("summary");
            summary.textContent = result.error ? "Reason" : "Breakdown / exclusions";
            details.append(summary);
            const list = document.createElement("ul");
            for (const text of [
                ...(result.error ? [result.error] : []),
                ...result.components.map(component => component.label + ": " + money(component.amount) + " / month (" + component.product + "; meter " + component.meter + ")"),
                ...result.notes, excluded
            ]) {
                const item = document.createElement("li");
                item.textContent = text;
                list.append(item);
            }
            details.append(list);
            cell.append(details);
        }
        status.textContent = baseStatus + (regionSelect.value ? " Priced: " + priced + "; unavailable: " + unavailable + "." : "");
    }
    for (const control of [regionSelect, planSelect, ahb, assumeGen5]) control.addEventListener("change", render);
    window.AzureSqlPricing = { estimate, specs, snapshot };
})();
