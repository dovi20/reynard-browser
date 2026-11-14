/*
 * Reynard site bridge (web notifications)
 *
 * Gecko on iOS has no backend for the web Notification API, so a site's own
 * notifications ("tell me when the response is ready") would go nowhere. This
 * replaces window.Notification in the page with one that hands notifications to
 * the native app, which asks the user for permission and shows them through iOS.
 *
 * Runs at document_start, before the site's scripts read window.Notification.
 * The page object is reached through Gecko's Xray helpers (wrappedJSObject,
 * exportFunction, cloneInto), so the site's content security policy does not
 * get in the way. If anything here fails, the page keeps what it had.
 *
 * Messages (browser.runtime.sendNativeMessage):
 *   { type: "web-notification-permission" }            -> { permission }
 *   { type: "web-notification-request" }               -> { permission }
 *   { type: "web-notification", id, title, body, tag, url }
 *   { type: "web-notification-close", id }
 */
"use strict";

(() => {
  if (window.top !== window) {
    return;
  }

  const NATIVE_APP = "reynard_site_bridge";
  const PERMISSIONS = ["default", "granted", "denied"];

  const page = window.wrappedJSObject;
  if (!page || typeof exportFunction !== "function" || typeof cloneInto !== "function") {
    return;
  }

  const send = (message) => {
    try {
      return browser.runtime.sendNativeMessage(NATIVE_APP, message).catch(() => null);
    } catch (error) {
      return Promise.resolve(null);
    }
  };

  let permission = "default";
  let counter = 0;

  const adoptPermission = (reply) => {
    const value = reply && reply.permission;
    if (PERMISSIONS.includes(value)) {
      permission = value;
    }
    return permission;
  };

  // Fires an event on a notification the way the browser would: listeners first,
  // then the on<type> handler the page may have assigned.
  const dispatch = (target, type) => {
    try {
      const event = new page.Event(type);
      target.dispatchEvent(event);
      const handler = target[`on${type}`];
      if (typeof handler === "function") {
        handler.call(target, event);
      }
    } catch (error) {
      // A page handler that throws must not break the bridge
    }
  };

  const readOption = (options, name) => {
    try {
      const value = options ? options[name] : undefined;
      return value === undefined || value === null ? "" : String(value);
    } catch (error) {
      return "";
    }
  };

  // Called by the page as `new Notification(title, options)`. Returns an object
  // that lives in the page, so the page can set handlers on it and close it.
  function createNotification(title, options) {
    const id = `${Date.now()}-${++counter}`;
    const text = title === undefined || title === null ? "" : String(title);
    const body = readOption(options, "body");
    const tag = readOption(options, "tag");

    const notification = new page.EventTarget();
    notification.title = text;
    notification.body = body;
    notification.tag = tag;
    notification.data = null;
    notification.onclick = null;
    notification.onclose = null;
    notification.onerror = null;
    notification.onshow = null;
    notification.close = exportFunction(() => {
      send({ type: "web-notification-close", id });
      dispatch(notification, "close");
    }, window);

    if (permission !== "granted") {
      setTimeout(() => dispatch(notification, "error"), 0);
      return notification;
    }

    send({ type: "web-notification", id, title: text, body, tag, url: location.href });
    setTimeout(() => dispatch(notification, "show"), 0);
    return notification;
  }

  const requestPermission = (callback) =>
    new page.Promise(
      exportFunction((resolve) => {
        send({ type: "web-notification-request" }).then((reply) => {
          const result = adoptPermission(reply);
          try {
            if (typeof callback === "function") {
              callback(result);
            }
          } catch (error) {
            // Legacy callback form; the promise still resolves
          }
          resolve(result);
        });
      }, window)
    );

  try {
    exportFunction(createNotification, window, { defineAs: "Notification" });
    const shim = page.Notification;

    const define = (name, descriptor) =>
      page.Object.defineProperty(shim, name, cloneInto(descriptor, window, { cloneFunctions: true }));

    define("permission", { get: () => permission, enumerable: true, configurable: true });
    define("maxActions", { value: 0, enumerable: true, configurable: true });
    define("requestPermission", {
      value: requestPermission,
      enumerable: true,
      configurable: true,
      writable: true,
    });
  } catch (error) {
    return;
  }

  send({ type: "web-notification-permission" }).then(adoptPermission);
})();
