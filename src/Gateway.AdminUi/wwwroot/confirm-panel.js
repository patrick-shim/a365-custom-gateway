(() => {
    const states = new Map();

    function initialize(panel, id) {
        if (!panel || !panel.isConnected || states.has(id)) {
            return;
        }

        const state = {
            panel,
            lastOutsideFocus: null,
            focusHandler: null
        };

        state.focusHandler = event => {
            const target = event.target;
            if (target instanceof HTMLElement && !panel.contains(target)) {
                state.lastOutsideFocus = target;
            }
        };

        const active = document.activeElement;
        if (active instanceof HTMLElement && !panel.contains(active)) {
            state.lastOutsideFocus = active;
        }

        document.addEventListener("focusin", state.focusHandler, true);
        states.set(id, state);
    }

    function restore(id) {
        const invoker = states.get(id)?.lastOutsideFocus;
        queueMicrotask(() => {
            const target = invoker instanceof HTMLElement && invoker.isConnected
                ? invoker : document.querySelector("h1");
            target?.focus({ preventScroll: true });
        });
    }

    function open(id) {
        requestAnimationFrame(() => {
            const panel = states.get(id)?.panel;
            const target = panel?.querySelector(
                "fluent-button:not([disabled]), button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])");
            target?.focus({ preventScroll: true });
        });
    }

    function dispose(id) {
        const state = states.get(id);
        if (!state) {
            return;
        }

        document.removeEventListener("focusin", state.focusHandler, true);
        states.delete(id);
    }

    window.A365Gateway = window.A365Gateway || {};
    window.A365Gateway.confirmPanel = { initialize, open, restore, dispose };
})();
