/*
 * Reynard site bridge for claude.ai (background)
 *
 * Claude streams each answer over a single completion request. While such a
 * request is open in a tab, tell that tab's content script that a response is
 * in progress. This does not depend on the page's markup.
 */
"use strict";

const COMPLETION_URLS = [
  "https://claude.ai/api/*completion*",
];

const openRequests = new Map(); // requestId -> tabId
const activeCounts = new Map(); // tabId -> number of open completion requests

const isCompletionRequest = (details) =>
  details.tabId >= 0 &&
  details.method === "POST" &&
  /\/(retry_)?completion(\?|$)/.test(details.url);

const notifyTab = (tabId) => {
  const active = (activeCounts.get(tabId) || 0) > 0;
  browser.tabs.sendMessage(tabId, { type: "network", active }).catch(() => {});
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

browser.webRequest.onBeforeRequest.addListener(
  (details) => {
    if (!isCompletionRequest(details) || openRequests.has(details.requestId)) {
      return;
    }
    openRequests.set(details.requestId, details.tabId);
    activeCounts.set(details.tabId, (activeCounts.get(details.tabId) || 0) + 1);
    notifyTab(details.tabId);
  },
  { urls: COMPLETION_URLS }
);

browser.webRequest.onCompleted.addListener(finish, { urls: COMPLETION_URLS });
browser.webRequest.onErrorOccurred.addListener(finish, { urls: COMPLETION_URLS });

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
