/*
 * Reynard site bridge (background)
 *
 * Chat sites stream each answer over one long POST request. While such a
 * request is open in a tab, tell that tab's content script that a response is
 * in progress. This does not depend on the page's markup.
 *
 * A request counts as a response stream when its URL matches a known chat
 * endpoint, or when the server answers a POST with an event stream.
 */
"use strict";

const ALL_HTTPS = { urls: ["https://*/*"] };

// On these hosts only the known chat endpoint counts; other sites fall back to
// "a POST answered with an event stream".
const KNOWN_HOSTS = /^https:\/\/(claude\.ai|chatgpt\.com|chat\.z\.ai)\//;

const KNOWN_STREAM_URLS = [
  // Claude
  /^https:\/\/claude\.ai\/api\/.*\/(retry_)?completion(\?|$)/,
  // ChatGPT
  /^https:\/\/chatgpt\.com\/backend-(api|anon)\/(f\/)?conversation(\?|$)/,
  // Z.ai
  /^https:\/\/chat\.z\.ai\/api\/(v\d+\/)?chat\/completions(\?|$)/,
];

const openRequests = new Map(); // requestId -> tabId
const activeCounts = new Map(); // tabId -> number of open response streams

const notifyTab = (tabId) => {
  const active = (activeCounts.get(tabId) || 0) > 0;
  browser.tabs.sendMessage(tabId, { type: "network", active }).catch(() => {});
};

const begin = (details) => {
  if (details.tabId < 0 || openRequests.has(details.requestId)) {
    return;
  }
  openRequests.set(details.requestId, details.tabId);
  activeCounts.set(details.tabId, (activeCounts.get(details.tabId) || 0) + 1);
  notifyTab(details.tabId);
};

const finish = (details) => {
  const tabId = openRequests.get(details.requestId);
  if (tabId === undefined) {
    return;
  }
  openRequests.delete(details.requestId);
  const count = Math.max(0, (activeCounts.get(tabId) || 0) - 1);
  if (count === 0) {
    activeCounts.delete(tabId);
  } else {
    activeCounts.set(tabId, count);
  }
  notifyTab(tabId);
};

const isEventStream = (details) =>
  (details.responseHeaders || []).some(
    (header) =>
      header.name.toLowerCase() === "content-type" &&
      (header.value || "").toLowerCase().includes("text/event-stream")
  );

browser.webRequest.onBeforeRequest.addListener((details) => {
  if (details.method === "POST" && KNOWN_STREAM_URLS.some((pattern) => pattern.test(details.url))) {
    begin(details);
  }
}, ALL_HTTPS);

browser.webRequest.onHeadersReceived.addListener(
  (details) => {
    if (details.method === "POST" && !KNOWN_HOSTS.test(details.url) && isEventStream(details)) {
      begin(details);
    }
  },
  ALL_HTTPS,
  ["responseHeaders"]
);

browser.webRequest.onCompleted.addListener(finish, ALL_HTTPS);
browser.webRequest.onErrorOccurred.addListener(finish, ALL_HTTPS);

browser.tabs.onRemoved.addListener((tabId) => {
  activeCounts.delete(tabId);
  for (const [requestId, requestTabId] of openRequests) {
    if (requestTabId === tabId) {
      openRequests.delete(requestId);
    }
  }
});

// A content script that (re)loads asks for the current state of its tab.
browser.runtime.onMessage.addListener((message, sender) => {
  if (message && message.type === "networkState" && sender.tab) {
    return Promise.resolve({ active: (activeCounts.get(sender.tab.id) || 0) > 0 });
  }
  return undefined;
});
