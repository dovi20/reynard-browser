/*
 * Reynard site bridge for claude.ai
 *
 * Watches the page for a response that is being generated and tells the native
 * app when one starts and when it finishes, so the app can stay alive in the
 * background while Claude is still writing and post a notification when it is done.
 *
 * Messages (browser.runtime.sendNativeMessage):
 *   { type: "ready" }
 *   { type: "activity", active: true,  title, url }
 *   { type: "activity", active: false, title, url, preview }
 */
"use strict";

(() => {
  if (window.top !== window) {
    return;
  }

  const NATIVE_APP = "reynard_site_bridge";
  const FINISH_DEBOUNCE_MS = 1500;
  const POLL_MS = 2000;
  const PREVIEW_LENGTH = 180;

  const send = (message) => {
    try {
      return browser.runtime.sendNativeMessage(NATIVE_APP, message).catch(() => null);
    } catch (error) {
      return Promise.resolve(null);
    }
  };

  // Set by the background script while a completion request is open in this tab.
  let networkActive = false;

  // A response is in progress while its completion request is open, while an
  // assistant message is marked as streaming, or while "Stop response" is on screen.
  const isGenerating = () =>
    networkActive ||
    !!document.querySelector('[data-is-streaming="true"]') ||
    !!document.querySelector('button[aria-label*="stop" i][aria-label*="respon" i]');

  const conversationTitle = () =>
    (document.title || "").replace(/\s*[-–—|]\s*Claude\s*$/i, "").trim();

  const lastResponsePreview = () => {
    const messages = document.querySelectorAll("[data-is-streaming]");
    const last = messages[messages.length - 1];
    if (!last) {
      return "";
    }
    const text = (last.innerText || last.textContent || "").replace(/\s+/g, " ").trim();
    return text.length > PREVIEW_LENGTH ? `${text.slice(0, PREVIEW_LENGTH - 1)}…` : text;
  };

  let generating = false;
  let finishTimer = null;

  const check = () => {
    if (isGenerating()) {
      if (finishTimer) {
        clearTimeout(finishTimer);
        finishTimer = null;
      }
      if (!generating) {
        generating = true;
        send({ type: "activity", active: true, title: conversationTitle(), url: location.href });
      }
      return;
    }

    if (generating && !finishTimer) {
      // Tool calls and thinking blocks can briefly clear the streaming state; wait before calling it done.
      finishTimer = setTimeout(() => {
        finishTimer = null;
        if (isGenerating()) {
          return;
        }
        generating = false;
        send({
          type: "activity",
          active: false,
          title: conversationTitle(),
          url: location.href,
          preview: lastResponsePreview(),
        });
      }, FINISH_DEBOUNCE_MS);
    }
  };

  let scheduled = false;
  const schedule = () => {
    if (scheduled) {
      return;
    }
    scheduled = true;
    setTimeout(() => {
      scheduled = false;
      check();
    }, 250);
  };

  new MutationObserver(schedule).observe(document.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["data-is-streaming", "aria-label"],
  });
  setInterval(check, POLL_MS);

  browser.runtime.onMessage.addListener((message) => {
    if (message && message.type === "network") {
      networkActive = !!message.active;
      schedule();
    }
  });
  browser.runtime
    .sendMessage({ type: "networkState" })
    .then((state) => {
      networkActive = !!(state && state.active);
      schedule();
    })
    .catch(() => {});

  send({ type: "ready" });
  check();
})();
