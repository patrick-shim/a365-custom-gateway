window.A365Gateway = window.A365Gateway || {};

window.A365Gateway.copyTextFrom = async function (element) {
    if (!(element instanceof HTMLTextAreaElement) || element.readOnly !== true) {
        throw new Error("The copy source is invalid.");
    }

    if (window.isSecureContext && navigator.clipboard) {
        await navigator.clipboard.writeText(element.value);
        return;
    }

    element.focus();
    element.select();
    if (!document.execCommand("copy")) {
        throw new Error("The browser did not copy the command.");
    }
};
