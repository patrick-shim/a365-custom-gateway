(() => {
    const states = new WeakMap();

    function initialize(panel) {
        if (!panel || states.has(panel)) {
            return;
        }

        const state = {
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
        states.set(panel, state);
    }

    function restore(panel) {
        const target = states.get(panel)?.lastOutsideFocus;
        if (!(target instanceof HTMLElement) || !target.isConnected) {
            return;
        }

        queueMicrotask(() => target.focus({ preventScroll: true }));
    }

    function open(panel) {
        requestAnimationFrame(() => {
            const target = panel?.querySelector(
                "fluent-button:not([disabled]), button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])");
            target?.focus({ preventScroll: true });
        });
    }

    function dispose(panel) {
        const state = states.get(panel);
        if (!state) {
            return;
        }

        document.removeEventListener("focusin", state.focusHandler, true);
        states.delete(panel);
    }

    window.A365Gateway = window.A365Gateway || {};
    window.A365Gateway.confirmPanel = { initialize, open, restore, dispose };
})();
