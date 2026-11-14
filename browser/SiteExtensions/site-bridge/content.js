/*
 * Reynard site bridge (content)
 *
 * Tells the native app when the site starts and finishes writing a response,
 * so the app can stay alive in the background while the answer is still being
 * written and post a notification when it is done.
 *
 * Signals: an open response stream (reported by the background script, works
 * on any site), plus page markup on the sites listed in PROFILES.
 *
 * Messages (browser.runtime.sendNativeMessage):
 *   { type: "ready", url }
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

  const PROFILES = [
    {
      host: /(^|\.)claude\.ai$/,
      // An assistant message marked as streaming, or the "Stop response" button
      streaming: [
        '[data-is-streaming="true"]',
        'button[aria-label*="stop" i][aria-label*="respon" i]',
      ],
      messages: "[data-is-streaming]",
    },
    {
      host: /(^|\.)chatgpt\.com$/,
      streaming: ['button[data-testid="stop-button"]'],
      messages: '[data-message-author-role="assistant"]',
    },
  ];
  const BRAND_SUFFIX = /\s*[-–—|·]\s*(Claude|ChatGPT|Z\.ai|Gemini|DeepSeek|Copilot|Grok|Perplexity)\s*$/i;
  const BRAND_ONLY = /^(Claude|ChatGPT|Z\.ai|Gemini|DeepSeek|Copilot|Grok|Perplexity|New chat)$/i;

  const profile = PROFILES.find((entry) => entry.host.test(location.hostname)) || {
    streaming: [],
    messages: null,
  };

  const send = (message) => {
    try {
      return browser.runtime.sendNativeMessage(NATIVE_APP, message).catch(() => null);
    } catch (error) {
      return Promise.resolve(null);
    }
  };

  // Set by the background script while a response stream is open in this tab.
  let networkActive = false;

  const isGenerating = () =>
    networkActive || profile.streaming.some((selector) => !!document.querySelector(selector));

  const conversationTitle = () => {
    const title = (document.title || "").replace(BRAND_SUFFIX, "").trim();
    return BRAND_ONLY.test(title) ? "" : title;
  };

  const lastResponsePreview = () => {
    if (!profile.messages) {
      return "";
    }
    const messages = document.querySelectorAll(profile.messages);
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
      // Tool calls and thinking blocks can briefly end one stream and start another; wait before calling it done.
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

  if (profile.streaming.length) {
    new MutationObserver(schedule).observe(document.documentElement, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["data-is-streaming", "aria-label", "data-testid"],
    });
    setInterval(check, POLL_MS);
  }

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

  send({ type: "ready", url: location.href });
  check();
})();
