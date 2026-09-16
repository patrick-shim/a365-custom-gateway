const maximumSampleBytes = 8192;
const maximumBatchBytes = 65536;
const maximumPositiveSamples = 100;
const maximumBatchPositives = 8;
const guid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const encoder = new TextEncoder();
export const browserExecutionBudgetMilliseconds = 210000;
const domain = encoder.encode("A365Gateway.PurviewRuntimeTest.Sample.v1\0");

export function exactUtf8(content) {
    if (typeof content !== "string" || content.length < 1 || content.length > maximumSampleBytes)
        throw new Error("An approved example is empty or exceeds the sample limit.");
    for (let index = 0; index < content.length; index++) {
        const value = content.charCodeAt(index);
        if (value >= 0xd800 && value <= 0xdbff) {
            const next = content.charCodeAt(++index);
            if (!(next >= 0xdc00 && next <= 0xdfff))
                throw new Error("An approved example contains invalid Unicode.");
        } else if (value >= 0xdc00 && value <= 0xdfff) {
            throw new Error("An approved example contains invalid Unicode.");
        }
    }
    const bytes = encoder.encode(content);
    if (bytes.length > maximumSampleBytes) {
        bytes.fill(0);
        throw new Error("An approved example exceeds 8 KiB of exact UTF-8.");
    }
    return bytes;
}

export async function commitSample(suiteNonce, caseId, intendedSensitiveInformationTypeId, content) {
    if (!/^[0-9a-f]{64}$/.test(suiteNonce) || !guid.test(caseId) ||
        (intendedSensitiveInformationTypeId !== null && !guid.test(intendedSensitiveInformationTypeId)))
        throw new Error("The runtime manifest identity is invalid.");
    const nonce = Uint8Array.from(suiteNonce.match(/../g), value => Number.parseInt(value, 16));
    const bytes = exactUtf8(content);
    const payload = new Uint8Array(domain.length + nonce.length + 4 + bytes.length);
    try {
        payload.set(domain);
        payload.set(nonce, domain.length);
        new DataView(payload.buffer).setUint32(domain.length + nonce.length, bytes.length, true);
        payload.set(bytes, domain.length + nonce.length + 4);
        const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", payload));
        return {
            caseId, intendedSensitiveInformationTypeId,
            contentHash: "sha256:" + Array.from(digest, value => value.toString(16).padStart(2, "0")).join(""),
            utf8ByteCount: bytes.length
        };
    } finally {
        nonce.fill(0);
        bytes.fill(0);
        payload.fill(0);
    }
}

export function planBatches(suite) {
    const batches = [];
    let current = [];
    let size = suite.negativeSample.utf8ByteCount;
    for (const sample of suite.positiveSamples) {
        if (current.length === maximumBatchPositives || size + sample.utf8ByteCount > maximumBatchBytes) {
            if (!current.length) throw new Error("The batch exceeds its byte limit.");
            batches.push(current);
            current = [];
            size = suite.negativeSample.utf8ByteCount;
        }
        current.push(sample.caseId);
        size += sample.utf8ByteCount;
    }
    if (current.length) batches.push(current);
    return batches;
}

export function createSession(root, notifications) {
    let frozen = null;
    let generation = 0;
    let disposed = false;
    let executing = false;
    let activeAbort = null;
    const usedAuthorizations = new Set();
    const inputs = () => Array.from(root.querySelectorAll("textarea[data-runtime-sample]"));
    const clear = () => {
        activeAbort?.abort();
        generation++;
        if (frozen) frozen.samples.clear();
        frozen = null;
        for (const input of inputs()) {
            input.value = "";
            input.readOnly = false;
        }
    };
    const changed = () => {
        generation++;
        if (frozen) {
            frozen.samples.clear();
            frozen = null;
            for (const input of inputs()) input.readOnly = false;
            // A notification only: no content, length, or keystroke is sent to the circuit.
            void notifications.invokeMethodAsync("RuntimeInputsChanged").catch(() => {});
        }
    };
    const leaving = () => clear();
    root.addEventListener("input", changed);
    globalThis.addEventListener?.("pagehide", leaving);

    return {
        async prepare() {
            if (disposed || executing || root.dataset.policyMode === "Disabled")
                throw new Error("This runtime test is not available.");
            if (frozen) return { suite: frozen.suite, batches: frozen.batches };
            const version = generation;
            const positiveInputs = Array.from(root.querySelectorAll("textarea[data-runtime-positive]"));
            const negativeInput = root.querySelector("textarea[data-runtime-negative]");
            if (positiveInputs.length < 1 || positiveInputs.length > maximumPositiveSamples || !negativeInput)
                throw new Error("A complete approved example suite is required.");
            const raw = positiveInputs.map(input => ({
                caseId: crypto.randomUUID(), id: input.dataset.sitId, content: input.value, input
            }));
            raw.push({ caseId: crypto.randomUUID(), id: null, content: negativeInput.value, input: negativeInput });
            const nonce = new Uint8Array(32);
            crypto.getRandomValues(nonce);
            const suiteNonce = Array.from(nonce, value => value.toString(16).padStart(2, "0")).join("");
            nonce.fill(0);
            const manifests = [];
            for (const sample of raw)
                manifests.push(await commitSample(suiteNonce, sample.caseId, sample.id, sample.content));
            if (generation !== version || disposed || root.isConnected === false)
                throw new Error("Examples changed while the manifest was being prepared.");
            if (new Set(manifests.map(item => item.contentHash)).size !== manifests.length)
                throw new Error("Every positive example and the clean negative must be distinct.");
            const suite = Object.freeze({
                suiteNonce,
                positiveSamples: Object.freeze(manifests.slice(0, -1).map(Object.freeze)),
                negativeSample: Object.freeze(manifests[manifests.length - 1])
            });
            frozen = {
                suite, batches: Object.freeze(planBatches(suite).map(Object.freeze)),
                samples: new Map(raw.map(item => [item.caseId, item.content])),
                bindings: raw.map(item => ({ caseId: item.caseId, input: item.input }))
            };
            for (const input of inputs()) input.readOnly = true;
            // Only this hash-only projection crosses JS interop.
            return { suite: frozen.suite, batches: frozen.batches };
        },
        async execute(authorization) {
            if (globalThis.location && globalThis.location.protocol !== "https:")
                throw new Error("Approved examples can only be sent over HTTPS.");
            if (disposed || executing || !frozen || authorization.policyMode === "Disabled" ||
                root.dataset.policyMode === "Disabled" ||
                root.dataset.profileId !== authorization.profileId || root.dataset.profileVersion !== authorization.expectedRowVersion ||
                usedAuthorizations.has(authorization.reviewTokenId) ||
                authorization.suiteNonce !== frozen.suite.suiteNonce ||
                !guid.test(authorization.profileId) || !guid.test(authorization.reviewTokenId) ||
                authorization.negativeCaseId !== frozen.suite.negativeSample.caseId)
                throw new Error("Fresh matching runtime authorization is required.");
            const unchanged = () => frozen &&
                frozen.bindings.every(binding => binding.input.value === frozen.samples.get(binding.caseId));
            if (!unchanged()) throw new Error("Examples changed after review.");
            const ids = authorization.positiveCaseIds;
            if (!Array.isArray(ids) || ids.length < 1 || ids.length > maximumBatchPositives ||
                new Set(ids).size !== ids.length ||
                ids.some(id => !frozen.suite.positiveSamples.some(sample => sample.caseId === id)))
                throw new Error("The reviewed batch does not match the frozen suite.");
            const chosen = [...ids, authorization.negativeCaseId];
            const total = chosen.reduce((sum, id) => sum +
                [...frozen.suite.positiveSamples, frozen.suite.negativeSample].find(item => item.caseId === id).utf8ByteCount, 0);
            if (total > maximumBatchBytes) throw new Error("The reviewed batch exceeds its byte limit.");
            executing = true;
            usedAuthorizations.add(authorization.reviewTokenId);
            const abort = new AbortController();
            activeAbort = abort;
            const timer = setTimeout(() => abort.abort(), browserExecutionBudgetMilliseconds);
            try {
                // Only the safe operation ID is retained in the URL for GET recovery.
                if (globalThis.location && globalThis.history) {
                    const url = new URL(globalThis.location.href);
                    url.searchParams.set("runtimeTest", authorization.reviewTokenId);
                    url.searchParams.set("runtimeProfile", authorization.profileId);
                    globalThis.history.replaceState(null, "", url);
                }
                const csrfResponse = await fetch("/portal/protection/runtime-tests/antiforgery", {
                    credentials: "same-origin", cache: "no-store", redirect: "error",
                    signal: AbortSignal.any([abort.signal, AbortSignal.timeout(10000)])
                });
                if (!csrfResponse.ok) throw new Error("Runtime authorization could not be validated.");
                const csrf = await csrfResponse.json();
                if (csrf.headerName !== "X-Gateway-CSRF" || typeof csrf.requestToken !== "string")
                    throw new Error("Runtime authorization could not be validated.");
                if (!unchanged() || root.dataset.policyMode === "Disabled" ||
                    root.dataset.profileId !== authorization.profileId || root.dataset.profileVersion !== authorization.expectedRowVersion)
                    throw new Error("The reviewed runtime context changed.");
                // Raw text travels exclusively in this one explicit HTTPS request, never JS interop.
                const response = await fetch(`/portal/protection/runtime-tests/${authorization.profileId}/execute`, {
                    method: "POST", credentials: "same-origin", cache: "no-store", redirect: "error", signal: abort.signal,
                    headers: { "Content-Type": "application/json", [csrf.headerName]: csrf.requestToken },
                    body: JSON.stringify({
                        reviewTokenId: authorization.reviewTokenId,
                        reviewToken: authorization.reviewToken,
                        idempotencyKey: authorization.idempotencyKey,
                        expectedRowVersion: authorization.expectedRowVersion,
                        samples: chosen.map(caseId => ({ caseId, content: frozen.samples.get(caseId) }))
                    })
                });
                if (!response.ok) return { report: null, outcomeUnknown: true, operationId: authorization.reviewTokenId };
                return { report: await response.json(), outcomeUnknown: false, operationId: authorization.reviewTokenId };
            } catch {
                // Never echo response bodies or exceptions that could contain sample content.
                return { report: null, outcomeUnknown: true, operationId: authorization.reviewTokenId };
            } finally {
                clearTimeout(timer);
                authorization.reviewToken = null;
                executing = false;
                activeAbort = null;
            }
        },
        clear,
        dispose() {
            disposed = true;
            clear();
            root.removeEventListener("input", changed);
            globalThis.removeEventListener?.("pagehide", leaving);
        }
    };
}
