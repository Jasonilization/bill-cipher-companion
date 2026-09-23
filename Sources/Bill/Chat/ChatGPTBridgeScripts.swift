import Foundation

/// The two pieces of JS/CSS injected into the real chatgpt.com page. Both are
/// deliberately best-effort and fail soft: chatgpt.com's DOM can change at
/// any time (there is no supported API for this — see `ChatBridge`'s doc
/// comment for why we're embedding the real site rather than calling the
/// OpenAI API), so neither script assumes specific markup will keep existing.
enum ChatGPTBridgeScripts {
    /// Hides ChatGPT's own outer chrome (sidebar/top nav) so the embedded
    /// page reads as part of our floating panel rather than a full website.
    /// Best-effort: these selectors are a reasonable guess at today's
    /// chatgpt.com structure and may need revisiting if OpenAI reshuffles
    /// their markup — if none of them match anything, this is a no-op and
    /// the page still displays (just with its normal chrome visible).
    static let hideChromeCSS = """
    nav[aria-label="Chat history"], #sidebar, [data-testid="sidebar"],
    #page-header, header[data-testid="page-header"] {
        display: none !important;
    }
    body, html { background: transparent !important; }
    """

    /// Rather than depending on chatgpt.com's exact "stop generating" button
    /// markup (which changes often), this watches for *any* sustained burst
    /// of DOM mutations in the main content area and treats that as "Bill
    /// should look like he's paying attention" — debounced back to idle
    /// after a quiet period. Less precise than matching a specific button,
    /// but far more resilient to redesigns.
    static let observeGeneratingStateJS = """
    (function() {
        if (window.__billBridgeInstalled) { return; }
        window.__billBridgeInstalled = true;

        let debounceTimer = null;
        let isGenerating = false;

        function post(value) {
            if (value === isGenerating) { return; }
            isGenerating = value;
            try {
                window.webkit.messageHandlers.billBridge.postMessage(value ? "generating" : "idle");
            } catch (e) {}
        }

        function onMutation() {
            post(true);
            if (debounceTimer) { clearTimeout(debounceTimer); }
            debounceTimer = setTimeout(function() { post(false); }, 900);
        }

        function attach() {
            const target = document.querySelector('main') || document.body;
            const observer = new MutationObserver(onMutation);
            observer.observe(target, { childList: true, subtree: true, characterData: true });
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', attach);
        } else {
            attach();
        }
    })();
    """

    /// Defines `window.billSendMessage`/`window.billGetLastResponse` once,
    /// so later calls from Swift (via `WebPage.callJavaScript`, in the same
    /// isolated content world these were defined in) can just invoke them.
    /// Best-effort, same as everything else here: chatgpt.com's composer
    /// and message markup can change, so both functions try a couple of
    /// reasonable selectors and fail soft (return false/null) rather than
    /// throw — a failed injection means the message just doesn't send
    /// rather than crashing anything.
    static let chatActionsJS = """
    (function() {
        if (window.billSendMessage) { return; }

        window.billSendMessage = function(text) {
            try {
                const composer = document.querySelector('#prompt-textarea')
                    || document.querySelector('[contenteditable="true"]');
                if (!composer) { return false; }
                composer.focus();
                composer.innerText = text;
                composer.dispatchEvent(new InputEvent('input', { bubbles: true }));
                setTimeout(function() {
                    const sendButton = document.querySelector('[data-testid="send-button"]')
                        || document.querySelector('button[aria-label="Send prompt"]');
                    if (sendButton && !sendButton.disabled) {
                        sendButton.click();
                    } else {
                        composer.dispatchEvent(new KeyboardEvent('keydown', {
                            key: 'Enter', code: 'Enter', bubbles: true, cancelable: true
                        }));
                    }
                }, 80);
                return true;
            } catch (e) {
                return false;
            }
        };

        window.billGetLastResponse = function() {
            try {
                const turns = document.querySelectorAll('[data-message-author-role="assistant"]');
                if (turns.length === 0) { return null; }
                const last = turns[turns.length - 1];
                return last.innerText || last.textContent || null;
            } catch (e) {
                return null;
            }
        };
    })();
    """
}
