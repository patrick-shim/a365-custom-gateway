window.A365Gateway = window.A365Gateway || {};

function retainGatewayRecovery(location, key, identifier) {
    const current = new URL(window.location.href);
    const target = new URL(location, current.href);
    const currentContext = new URLSearchParams(current.search);
    const targetContext = new URLSearchParams(target.search);
    currentContext.delete(key);
    targetContext.delete(key);
    if (target.origin !== current.origin || target.pathname !== current.pathname ||
        target.username !== current.username || target.password !== current.password ||
        targetContext.toString() !== currentContext.toString() ||
        target.searchParams.getAll(key).length !== 1 ||
        target.searchParams.get(key) !== identifier) {
        throw new Error("The recovery location is invalid.");
    }
    // Same-page scrolling can change the fragment without notifying the server.
    target.hash = current.hash;
    window.history.replaceState(window.history.state, "", target.href);
    return window.location.href === target.href;
}

window.A365Gateway.retainRegistrationRecovery = function (location, externalAgentId) {
    return retainGatewayRecovery(location, "pendingExternalId", externalAgentId);
};

window.A365Gateway.retainProtectionRecovery = function (location, operationId) {
    if (!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(operationId) ||
        operationId === "00000000-0000-0000-0000-000000000000") {
        throw new Error("The protection operation is invalid.");
    }
    return retainGatewayRecovery(location, "operation", operationId);
};

window.A365Gateway.focusFirstInvalid = function (formId) {
    const form = document.getElementById(formId);
    const target = form?.querySelector(".invalid, [aria-invalid='true']") ??
        form?.querySelector("input, select, textarea");
    target?.focus();
};

window.A365Gateway.focusHeading = function () {
    document.querySelector("h1")?.focus();
};

window.A365Gateway.copyTextFrom = async function (element) {
    if (!(element instanceof HTMLTextAreaElement || element instanceof HTMLInputElement) ||
        element.readOnly !== true) {
        throw new Error("The copy source is invalid.");
    }

    if (window.isSecureContext && navigator.clipboard) {
        try {
            await navigator.clipboard.writeText(element.value);
        } catch (error) {
            element.focus();
            element.select();
            throw error;
        }
        return;
    }

    element.focus();
    element.select();
    if (!document.execCommand("copy")) {
        throw new Error("The browser did not copy the text.");
    }
};
