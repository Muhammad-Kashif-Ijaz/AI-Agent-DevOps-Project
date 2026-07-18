(() => {
  "use strict";

  const dom = {
    root: document.documentElement,
    appShell: document.querySelector("#appShell"),
    sidebar: document.querySelector("#sidebar"),
    sidebarScrim: document.querySelector("#sidebarScrim"),
    sidebarClose: document.querySelector("#sidebarClose"),
    menuButton: document.querySelector("#menuButton"),
    newChatButton: document.querySelector("#newChatButton"),
    historySearch: document.querySelector("#historySearch"),
    historyGroups: document.querySelector("#historyGroups"),
    historyLoading: document.querySelector("#historyLoading"),
    historyEmpty: document.querySelector("#historyEmpty"),
    sidebarThemeToggle: document.querySelector("#sidebarThemeToggle"),
    themeIconButton: document.querySelector("#themeIconButton"),
    presenceDot: document.querySelector("#presenceDot"),
    presenceLabel: document.querySelector("#presenceLabel"),
    conversationTitle: document.querySelector("#conversationTitle"),
    chatScroll: document.querySelector("#chatScroll"),
    emptyState: document.querySelector("#emptyState"),
    messages: document.querySelector("#messages"),
    scrollAnchor: document.querySelector("#scrollAnchor"),
    jumpButton: document.querySelector("#jumpButton"),
    composerForm: document.querySelector("#composerForm"),
    composerInput: document.querySelector("#composerInput"),
    sendButton: document.querySelector("#sendButton"),
    composerHint: document.querySelector("#composerHint"),
    voiceButton: document.querySelector("#voiceButton"),
    listeningState: document.querySelector("#listeningState"),
    toastRegion: document.querySelector("#toastRegion"),
    themeMeta: document.querySelector('meta[name="theme-color"]'),
  };

  const state = {
    chats: [],
    messages: [],
    currentChatId: null,
    sending: false,
    abortController: null,
    activeMenu: null,
    recognition: null,
    listening: false,
    shouldFollowStream: true,
    renderingFrame: null,
    statusTimer: null,
  };

  const icons = {
    keivo: '<svg class="keivo-glyph" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 3.5h4.8v6.1l5.3-6.1h5.6l-7.5 8.1H4z"/><path d="M4 12.5h8.2l7.5 8h-5.6l-5.3-5.9v5.9H4z"/><circle cx="20.7" cy="2.6" r="1.25"/></svg>',
    more: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="5" cy="12" r="1" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1" fill="currentColor" stroke="none"/><circle cx="19" cy="12" r="1" fill="currentColor" stroke="none"/></svg>',
    edit: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m14 5 5 5M4 20l3.5-.7L19 7.8a2.1 2.1 0 0 0-3-3L4.7 16.2 4 20Z"/></svg>',
    trash: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M9 7V4h6v3M7 7l1 13h8l1-13M10 11v5M14 11v5"/></svg>',
    copy: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="8" y="8" width="11" height="11" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/></svg>',
    check: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12 4 4L19 6"/></svg>',
    retry: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 7v5h-5M19 12a7.5 7.5 0 1 0-.8 4.3"/></svg>',
    external: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14 5h5v5M19 5l-8 8M18 13v5a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/></svg>',
  };

  function prefersReducedMotion() {
    return window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true;
  }

  function escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");
  }

  function safeUrl(value) {
    try {
      const url = new URL(String(value));
      return url.protocol === "https:" || url.protocol === "http:" ? url.href : null;
    } catch {
      return null;
    }
  }

  function inlineMarkdown(value, depth = 0) {
    const text = String(value ?? "");
    if (depth > 4) return escapeHtml(text);

    let output = "";
    let index = 0;

    while (index < text.length) {
      if (text.startsWith("**", index) || text.startsWith("__", index)) {
        const marker = text.slice(index, index + 2);
        const end = text.indexOf(marker, index + 2);
        if (end > index + 2) {
          output += `<strong>${inlineMarkdown(text.slice(index + 2, end), depth + 1)}</strong>`;
          index = end + 2;
          continue;
        }
      }

      if (text[index] === "`") {
        const end = text.indexOf("`", index + 1);
        if (end > index + 1) {
          output += `<code>${escapeHtml(text.slice(index + 1, end))}</code>`;
          index = end + 1;
          continue;
        }
      }

      if (text[index] === "[") {
        const labelEnd = text.indexOf("](", index + 1);
        const urlEnd = labelEnd === -1 ? -1 : text.indexOf(")", labelEnd + 2);
        if (labelEnd > index + 1 && urlEnd > labelEnd + 2) {
          const href = safeUrl(text.slice(labelEnd + 2, urlEnd));
          const label = inlineMarkdown(text.slice(index + 1, labelEnd), depth + 1);
          output += href
            ? `<a href="${escapeHtml(href)}" target="_blank" rel="noopener noreferrer">${label}</a>`
            : label;
          index = urlEnd + 1;
          continue;
        }
      }

      if (text[index] === "*" || text[index] === "_") {
        const marker = text[index];
        const end = text.indexOf(marker, index + 1);
        if (end > index + 1) {
          output += `<em>${inlineMarkdown(text.slice(index + 1, end), depth + 1)}</em>`;
          index = end + 1;
          continue;
        }
      }

      let next = index + 1;
      while (next < text.length && !"*_`[".includes(text[next])) next += 1;
      output += escapeHtml(text.slice(index, next));
      index = next;
    }

    return output;
  }

  function isBlockStart(line) {
    return (
      /^```/.test(line) ||
      /^#{1,3}\s+/.test(line) ||
      /^>\s?/.test(line) ||
      /^\s*[-*+]\s+/.test(line) ||
      /^\s*\d+[.)]\s+/.test(line)
    );
  }

  function renderMarkdown(value) {
    const lines = String(value ?? "").replaceAll("\r\n", "\n").split("\n");
    const output = [];
    let index = 0;

    while (index < lines.length) {
      const line = lines[index];
      if (!line.trim()) {
        index += 1;
        continue;
      }

      const fence = line.match(/^```\s*([^\s`]*)/);
      if (fence) {
        const language = fence[1] || "code";
        const code = [];
        index += 1;
        while (index < lines.length && !/^```\s*$/.test(lines[index])) {
          code.push(lines[index]);
          index += 1;
        }
        if (index < lines.length) index += 1;
        output.push(
          `<div class="code-block"><span class="code-label">${escapeHtml(language)}</span><pre><code>${escapeHtml(code.join("\n"))}</code></pre></div>`,
        );
        continue;
      }

      const heading = line.match(/^(#{1,3})\s+(.+)$/);
      if (heading) {
        const level = heading[1].length;
        output.push(`<h${level}>${inlineMarkdown(heading[2])}</h${level}>`);
        index += 1;
        continue;
      }

      if (/^>\s?/.test(line)) {
        const quoted = [];
        while (index < lines.length && /^>\s?/.test(lines[index])) {
          quoted.push(lines[index].replace(/^>\s?/, ""));
          index += 1;
        }
        output.push(`<blockquote>${inlineMarkdown(quoted.join("\n")).replaceAll("\n", "<br>")}</blockquote>`);
        continue;
      }

      const unordered = line.match(/^\s*[-*+]\s+(.+)$/);
      if (unordered) {
        const items = [];
        while (index < lines.length) {
          const match = lines[index].match(/^\s*[-*+]\s+(.+)$/);
          if (!match) break;
          items.push(`<li>${inlineMarkdown(match[1])}</li>`);
          index += 1;
        }
        output.push(`<ul>${items.join("")}</ul>`);
        continue;
      }

      const ordered = line.match(/^\s*\d+[.)]\s+(.+)$/);
      if (ordered) {
        const items = [];
        while (index < lines.length) {
          const match = lines[index].match(/^\s*\d+[.)]\s+(.+)$/);
          if (!match) break;
          items.push(`<li>${inlineMarkdown(match[1])}</li>`);
          index += 1;
        }
        output.push(`<ol>${items.join("")}</ol>`);
        continue;
      }

      const paragraph = [line.trim()];
      index += 1;
      while (index < lines.length && lines[index].trim() && !isBlockStart(lines[index])) {
        paragraph.push(lines[index].trim());
        index += 1;
      }
      output.push(`<p>${inlineMarkdown(paragraph.join("\n")).replaceAll("\n", "<br>")}</p>`);
    }

    return output.join("");
  }

  function getChatId(chat) {
    return String(chat?.id ?? chat?.chat_id ?? "");
  }

  function getChatTitle(chat) {
    return String(chat?.title || "Untitled conversation");
  }

  function getChatDate(chat) {
    const raw = chat?.updated_at || chat?.updatedAt || chat?.created_at || chat?.createdAt;
    const date = raw ? new Date(raw) : new Date();
    return Number.isNaN(date.getTime()) ? new Date() : date;
  }

  function getMessageRole(message) {
    const role = String(message?.role || "assistant").toLowerCase();
    return role === "user" ? "user" : "assistant";
  }

  function getMessageText(message) {
    if (typeof message?.content === "string") return message.content;
    if (typeof message?.text === "string") return message.text;
    if (Array.isArray(message?.content)) {
      return message.content
        .map((part) => (typeof part === "string" ? part : part?.text || ""))
        .filter(Boolean)
        .join("\n");
    }
    return "";
  }

  function getSources(message) {
    const candidates = message?.sources || message?.citations || [];
    if (!Array.isArray(candidates)) return [];
    const seen = new Set();
    return candidates
      .map((item) => {
        if (typeof item === "string") return { title: item, url: item };
        return { title: item?.title || item?.name || item?.url, url: item?.url || item?.href };
      })
      .filter((item) => {
        const href = safeUrl(item.url);
        if (!href || seen.has(href)) return false;
        item.url = href;
        seen.add(href);
        return true;
      })
      .slice(0, 8);
  }

  function setTheme(theme, persist = true) {
    const next = theme === "light" ? "light" : "dark";
    dom.root.dataset.theme = next;
    dom.themeMeta?.setAttribute("content", next === "light" ? "#f6f6f3" : "#0b0b0c");
    const label = next === "light" ? "Use dark theme" : "Use light theme";
    dom.sidebarThemeToggle.setAttribute("aria-label", label);
    dom.themeIconButton.setAttribute("aria-label", label);
    dom.sidebarThemeToggle.setAttribute("aria-pressed", String(next === "light"));
    dom.themeIconButton.setAttribute("aria-pressed", String(next === "light"));
    if (persist) {
      try {
        localStorage.setItem("keivo-theme", next);
      } catch {
        // The selected theme still applies for this session.
      }
    }
  }

  function toggleTheme() {
    const next = dom.root.dataset.theme === "dark" ? "light" : "dark";
    if (document.startViewTransition && !prefersReducedMotion()) {
      document.startViewTransition(() => setTheme(next));
    } else {
      setTheme(next);
    }
  }

  function initializeTheme() {
    let saved = null;
    try {
      saved = localStorage.getItem("keivo-theme");
    } catch {
      saved = null;
    }
    const preferred = window.matchMedia?.("(prefers-color-scheme: light)").matches ? "light" : "dark";
    setTheme(saved || preferred, false);
  }

  function showToast(message) {
    const toast = document.createElement("div");
    toast.className = "toast";
    toast.textContent = message;
    dom.toastRegion.append(toast);
    window.setTimeout(() => {
      toast.classList.add("is-leaving");
      window.setTimeout(() => toast.remove(), 190);
    }, 2500);
  }

  async function readJson(response) {
    try {
      return await response.json();
    } catch {
      return {};
    }
  }

  async function responseError(response, message = "Request interrupted") {
    const payload = await readJson(response);
    const detail = payload?.detail;
    const fields = detail && typeof detail === "object" ? { ...payload, ...detail } : payload;
    const error = new Error(message);
    error.status = response.status;
    error.detail = typeof detail === "string" ? detail : typeof fields?.message === "string" ? fields.message : "";
    error.retryAt = fields?.retry_at ?? fields?.retryAt ?? null;
    error.retryAfter = fields?.retry_after ?? fields?.retryAfter ?? response.headers.get("Retry-After");
    return error;
  }

  async function request(path, options = {}) {
    const response = await fetch(path, {
      ...options,
      headers: {
        Accept: "application/json",
        ...(options.body ? { "Content-Type": "application/json" } : {}),
        ...(options.headers || {}),
      },
    });
    if (!response.ok) {
      throw await responseError(response);
    }
    return readJson(response);
  }

  function setPresence(mode) {
    const preparing = mode === "preparing";
    const unavailable = mode === "unavailable";
    dom.presenceDot.classList.toggle("is-preparing", preparing);
    dom.presenceDot.classList.toggle("is-unavailable", unavailable);
    dom.presenceLabel.textContent = preparing
      ? "KEIVO is preparing"
      : unavailable
        ? "KEIVO is unavailable"
        : "Ready";
  }

  function scheduleStatusCheck(delay) {
    window.clearTimeout(state.statusTimer);
    state.statusTimer = window.setTimeout(loadStatus, delay);
  }

  async function loadStatus() {
    window.clearTimeout(state.statusTimer);
    try {
      const payload = await request("/api/status");
      const status = String(payload?.status || payload?.state || "").toLowerCase();
      const preparing = ["preparing", "starting", "warming", "loading"].some((word) => status.includes(word));
      const unavailable = payload?.ready === false || ["unavailable", "offline", "error"].some((word) => status.includes(word));
      if (preparing) {
        setPresence("preparing");
        scheduleStatusCheck(3500);
      } else if (unavailable) {
        setPresence("unavailable");
        scheduleStatusCheck(10000);
      } else {
        setPresence("ready");
      }
    } catch {
      setPresence("unavailable");
      scheduleStatusCheck(10000);
    }
  }

  async function loadChats({ quiet = false } = {}) {
    if (!quiet) dom.historyLoading.hidden = false;
    try {
      const payload = await request("/api/chats");
      state.chats = Array.isArray(payload) ? payload : payload?.chats || [];
      state.chats.sort((a, b) => getChatDate(b) - getChatDate(a));
      renderHistory();
    } catch {
      if (!quiet) showToast("Conversation history is unavailable right now.");
      renderHistory();
    } finally {
      dom.historyLoading.hidden = true;
    }
  }

  function dateGroup(date) {
    const today = new Date();
    const startToday = new Date(today.getFullYear(), today.getMonth(), today.getDate());
    const startDate = new Date(date.getFullYear(), date.getMonth(), date.getDate());
    const days = Math.round((startToday - startDate) / 86400000);
    if (days <= 0) return "Today";
    if (days === 1) return "Yesterday";
    if (days < 7) return "Previous 7 days";
    if (date.getFullYear() === today.getFullYear()) {
      return date.toLocaleDateString(undefined, { month: "long" });
    }
    return String(date.getFullYear());
  }

  function renderHistory() {
    closeChatMenu();
    const query = dom.historySearch.value.trim().toLocaleLowerCase();
    const chats = state.chats.filter((chat) => getChatTitle(chat).toLocaleLowerCase().includes(query));
    dom.historyGroups.replaceChildren();
    dom.historyEmpty.hidden = chats.length > 0;
    dom.historyEmpty.textContent = query ? "No matching conversations" : "No conversations yet";

    const groups = new Map();
    chats.forEach((chat) => {
      const label = dateGroup(getChatDate(chat));
      if (!groups.has(label)) groups.set(label, []);
      groups.get(label).push(chat);
    });

    groups.forEach((items, label) => {
      const section = document.createElement("section");
      section.className = "history-group";

      const heading = document.createElement("h2");
      heading.className = "history-group-title";
      heading.textContent = label;
      section.append(heading);

      const list = document.createElement("ul");
      list.className = "history-list";
      items.forEach((chat) => {
        const id = getChatId(chat);
        const item = document.createElement("li");
        item.className = `history-item${id === state.currentChatId ? " active" : ""}`;
        item.dataset.chatId = id;

        const openButton = document.createElement("button");
        openButton.className = "history-item-button";
        openButton.type = "button";
        openButton.setAttribute("aria-current", id === state.currentChatId ? "page" : "false");
        openButton.innerHTML = `<span>${escapeHtml(getChatTitle(chat))}</span>`;
        openButton.addEventListener("click", () => openChat(id));

        const more = document.createElement("button");
        more.className = "history-more";
        more.type = "button";
        more.setAttribute("aria-label", `Options for ${getChatTitle(chat)}`);
        more.setAttribute("aria-haspopup", "menu");
        more.innerHTML = icons.more;
        more.addEventListener("click", (event) => {
          event.stopPropagation();
          openChatMenu(chat, more, item);
        });

        item.append(openButton, more);
        list.append(item);
      });

      section.append(list);
      dom.historyGroups.append(section);
    });
  }

  function closeChatMenu() {
    if (!state.activeMenu) return;
    state.activeMenu.item?.classList.remove("menu-open");
    state.activeMenu.menu?.remove();
    state.activeMenu = null;
  }

  function positionMenu(menu, trigger) {
    const rect = trigger.getBoundingClientRect();
    const width = 148;
    let left = rect.right + 6;
    if (left + width > window.innerWidth - 8) left = rect.left - width - 6;
    let top = rect.top;
    if (top + menu.offsetHeight > window.innerHeight - 8) top = window.innerHeight - menu.offsetHeight - 8;
    menu.style.left = `${Math.max(8, left)}px`;
    menu.style.top = `${Math.max(8, top)}px`;
  }

  function openChatMenu(chat, trigger, item) {
    if (state.activeMenu?.item === item) {
      closeChatMenu();
      return;
    }
    closeChatMenu();
    const menu = document.createElement("div");
    menu.className = "chat-menu";
    menu.setAttribute("role", "menu");
    menu.innerHTML = `
      <button type="button" role="menuitem" data-action="rename">${icons.edit}<span>Rename</span></button>
      <button type="button" role="menuitem" class="danger" data-action="delete">${icons.trash}<span>Delete</span></button>
    `;
    document.body.append(menu);
    item.classList.add("menu-open");
    state.activeMenu = { chat, trigger, item, menu };
    positionMenu(menu, trigger);
    menu.querySelector('[data-action="rename"]').addEventListener("click", () => beginRename(chat, item));
    menu.querySelector('[data-action="delete"]').addEventListener("click", () => showDeleteConfirmation(chat, menu));
    menu.querySelector("button")?.focus();
  }

  function showDeleteConfirmation(chat, menu) {
    menu.innerHTML = `
      <button type="button" role="menuitem" class="danger" data-action="confirm">${icons.trash}<span>Delete now</span></button>
      <button type="button" role="menuitem" data-action="cancel"><span>Cancel</span></button>
    `;
    positionMenu(menu, state.activeMenu.trigger);
    menu.querySelector('[data-action="confirm"]').addEventListener("click", () => deleteChat(getChatId(chat)));
    menu.querySelector('[data-action="cancel"]').addEventListener("click", closeChatMenu);
    menu.querySelector("button")?.focus();
  }

  function beginRename(chat, item) {
    closeChatMenu();
    const id = getChatId(chat);
    const button = item.querySelector(".history-item-button");
    const input = document.createElement("input");
    input.className = "history-rename";
    input.value = getChatTitle(chat);
    input.maxLength = 100;
    input.setAttribute("aria-label", "Conversation title");
    button.hidden = true;
    item.querySelector(".history-more").hidden = true;
    item.prepend(input);
    input.focus();
    input.select();

    let finished = false;
    const finish = async (save) => {
      if (finished) return;
      finished = true;
      const title = input.value.trim();
      input.remove();
      button.hidden = false;
      item.querySelector(".history-more").hidden = false;
      if (!save || !title || title === getChatTitle(chat)) return;
      try {
        await request(`/api/chats/${encodeURIComponent(id)}`, {
          method: "PATCH",
          body: JSON.stringify({ title }),
        });
        chat.title = title;
        if (id === state.currentChatId) dom.conversationTitle.textContent = title;
        renderHistory();
      } catch {
        showToast("That title could not be saved.");
      }
    };
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        finish(true);
      } else if (event.key === "Escape") {
        event.preventDefault();
        finish(false);
      }
    });
    input.addEventListener("blur", () => finish(true));
  }

  async function deleteChat(id) {
    closeChatMenu();
    try {
      await request(`/api/chats/${encodeURIComponent(id)}`, { method: "DELETE" });
      state.chats = state.chats.filter((chat) => getChatId(chat) !== id);
      if (state.currentChatId === id) startNewChat({ focus: false });
      else renderHistory();
      showToast("Conversation deleted.");
    } catch {
      showToast("That conversation could not be deleted.");
    }
  }

  function setConversation(messages, title) {
    state.messages = Array.isArray(messages) ? messages : [];
    dom.conversationTitle.textContent = title || "New conversation";
    renderMessages();
  }

  async function openChat(id) {
    if (!id || id === state.currentChatId) {
      closeSidebar();
      return;
    }
    stopResponse();
    closeChatMenu();
    state.currentChatId = id;
    const selected = state.chats.find((chat) => getChatId(chat) === id);
    dom.conversationTitle.textContent = selected ? getChatTitle(selected) : "Conversation";
    dom.emptyState.hidden = true;
    dom.messages.classList.add("has-messages");
    dom.messages.innerHTML = `
      <article class="message message-assistant">
        <span class="assistant-mark" aria-hidden="true">${icons.keivo}</span>
        <div class="message-inner"><div class="thinking"><span class="thinking-dots"><span></span><span></span><span></span></span>Opening conversation</div></div>
      </article>`;
    renderHistory();
    closeSidebar();
    history.replaceState(null, "", `#chat=${encodeURIComponent(id)}`);

    try {
      const payload = await request(`/api/chats/${encodeURIComponent(id)}`);
      const chat = payload?.chat || selected || {};
      const messages = Array.isArray(payload?.messages)
        ? payload.messages
        : Array.isArray(payload?.chat?.messages)
          ? payload.chat.messages
          : [];
      if (state.currentChatId !== id) return;
      setConversation(messages, getChatTitle(chat));
      window.requestAnimationFrame(() => scrollToBottom(false));
    } catch {
      if (state.currentChatId !== id) return;
      startNewChat({ focus: false });
      showToast("That conversation could not be opened.");
    }
  }

  function startNewChat({ focus = true } = {}) {
    stopResponse();
    closeChatMenu();
    state.currentChatId = null;
    state.messages = [];
    dom.conversationTitle.textContent = "New conversation";
    renderMessages();
    renderHistory();
    history.replaceState(null, "", `${location.pathname}${location.search}`);
    closeSidebar();
    if (focus) window.setTimeout(() => dom.composerInput.focus(), 80);
  }

  function createTitle(content) {
    const clean = String(content).replace(/\s+/g, " ").trim();
    if (clean.length <= 54) return clean;
    return `${clean.slice(0, 53).trimEnd()}\u2026`;
  }

  async function ensureChat(firstMessage) {
    if (state.currentChatId) return state.currentChatId;
    const title = createTitle(firstMessage) || "New conversation";
    const payload = await request("/api/chats", {
      method: "POST",
      body: JSON.stringify({ title }),
    });
    const chat = payload?.chat || payload;
    const id = getChatId(chat);
    if (!id) throw new Error("Conversation unavailable");
    state.currentChatId = id;
    dom.conversationTitle.textContent = getChatTitle(chat) || title;
    state.chats.unshift({ ...chat, id, title: getChatTitle(chat) || title });
    renderHistory();
    history.replaceState(null, "", `#chat=${encodeURIComponent(id)}`);
    return id;
  }

  function createSourcesElement(sources) {
    const safeSources = getSources({ sources });
    if (!safeSources.length) return null;
    const wrap = document.createElement("div");
    wrap.className = "sources";
    wrap.setAttribute("aria-label", "Sources");
    safeSources.forEach((source) => {
      const link = document.createElement("a");
      link.className = "source-link";
      link.href = source.url;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.innerHTML = `${icons.external}<span>${escapeHtml(source.title || new URL(source.url).hostname)}</span>`;
      wrap.append(link);
    });
    return wrap;
  }

  function messageElement(message, index) {
    const role = getMessageRole(message);
    const article = document.createElement("article");
    article.className = `message message-${role}${message.pending ? " is-streaming" : ""}`;
    article.dataset.messageIndex = String(index);

    if (role === "assistant") {
      const mark = document.createElement("span");
      mark.className = "assistant-mark";
      mark.setAttribute("aria-hidden", "true");
      mark.innerHTML = icons.keivo;
      article.append(mark);
    }

    const inner = document.createElement("div");
    inner.className = "message-inner";

    if (role === "assistant") {
      const meta = document.createElement("div");
      meta.className = "message-meta";
      meta.textContent = "KEIVO";
      inner.append(meta);
    }

    const body = document.createElement("div");
    body.className = "message-body";
    const text = getMessageText(message);
    if (role === "user") {
      body.textContent = text;
    } else if (message.pending && !text) {
      body.innerHTML = '<div class="thinking"><span class="thinking-dots"><span></span><span></span><span></span></span>Thinking</div>';
    } else {
      body.innerHTML = renderMarkdown(text);
    }
    inner.append(body);

    const sourceElement = createSourcesElement(getSources(message));
    if (sourceElement) inner.append(sourceElement);

    if (message.error) {
      const error = document.createElement("p");
      error.className = "message-error";
      error.setAttribute("role", "status");
      error.textContent = message.error;
      inner.append(error);
    }

    if (role === "assistant" && text && !message.pending) {
      const actions = document.createElement("div");
      actions.className = "message-actions";
      actions.innerHTML = `
        <button class="message-action" type="button" data-action="copy" aria-label="Copy response">${icons.copy}</button>
        <button class="message-action" type="button" data-action="retry" aria-label="Ask again">${icons.retry}</button>
      `;
      actions.querySelector('[data-action="copy"]').addEventListener("click", (event) => copyResponse(text, event.currentTarget));
      actions.querySelector('[data-action="retry"]').addEventListener("click", () => retryMessage(index));
      inner.append(actions);
    }

    article.append(inner);
    return article;
  }

  function renderMessages() {
    dom.messages.replaceChildren();
    const hasMessages = state.messages.length > 0;
    dom.emptyState.hidden = hasMessages;
    dom.messages.classList.toggle("has-messages", hasMessages);
    state.messages.forEach((message, index) => dom.messages.append(messageElement(message, index)));
  }

  function updateStreamingMessage(index) {
    if (state.renderingFrame) return;
    state.renderingFrame = window.requestAnimationFrame(() => {
      state.renderingFrame = null;
      const article = dom.messages.querySelector(`[data-message-index="${index}"]`);
      const message = state.messages[index];
      if (!article || !message) return;
      const body = article.querySelector(".message-body");
      const text = getMessageText(message);
      body.innerHTML = text
        ? renderMarkdown(text)
        : '<div class="thinking"><span class="thinking-dots"><span></span><span></span><span></span></span>Thinking</div>';
      if (state.shouldFollowStream) scrollToBottom(false);
    });
  }

  async function copyResponse(text, button) {
    try {
      await navigator.clipboard.writeText(text);
      button.innerHTML = icons.check;
      button.setAttribute("aria-label", "Copied");
      window.setTimeout(() => {
        button.innerHTML = icons.copy;
        button.setAttribute("aria-label", "Copy response");
      }, 1600);
    } catch {
      showToast("Copy is unavailable here.");
    }
  }

  function retryMessage(index) {
    if (state.sending) return;
    for (let cursor = index - 1; cursor >= 0; cursor -= 1) {
      if (getMessageRole(state.messages[cursor]) === "user") {
        submitMessage(getMessageText(state.messages[cursor]));
        return;
      }
    }
  }

  function retryTime(error) {
    const at = error?.retryAt;
    if (typeof at === "string" && /^\d{1,2}:\d{2}(?:\s?[AP]M)?$/i.test(at.trim())) return at.trim();

    let date = null;
    if (at !== null && at !== undefined && at !== "") {
      if (typeof at === "number" || /^\d+(?:\.\d+)?$/.test(String(at))) {
        const numeric = Number(at);
        date = new Date(numeric > 1e12 ? numeric : numeric * 1000);
      } else {
        date = new Date(String(at));
      }
    } else if (error?.retryAfter !== null && error?.retryAfter !== undefined && error.retryAfter !== "") {
      const seconds = Number(error.retryAfter);
      date = Number.isFinite(seconds) ? new Date(Date.now() + Math.max(0, seconds) * 1000) : new Date(String(error.retryAfter));
    }

    if (!date || Number.isNaN(date.getTime())) return "";
    return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }

  function friendlyError(error) {
    const status = error?.status;
    if (status === 429) {
      const time = retryTime(error);
      if (time) return `Usage limit is over. Try again at ${time}.`;
      const detail = String(error?.detail || "").trim();
      if (detail) return detail.slice(0, 180);
      return "Usage limit is over. Please try again shortly.";
    }
    if (status === 413) return "That message is too long. Try sending it in smaller parts.";
    if (status === 503) return "KEIVO is preparing. Try again in a moment.";
    if (status === 502 || status === 504) return "KEIVO is unavailable right now. Please try again shortly.";
    if (status === 409) return "A response is already in progress. Stop it before trying again.";
    return "Something interrupted the response. Please try again.";
  }

  function mergeSources(target, sources) {
    const combined = [...getSources(target), ...getSources({ sources })];
    target.sources = getSources({ sources: combined });
  }

  function consumeStreamEvent(event, assistant, index) {
    const type = String(event?.type || event?.event || "").toLowerCase();
    if (type === "delta" || type.endsWith(".delta")) {
      assistant.content += String(event?.text ?? event?.delta ?? "");
      updateStreamingMessage(index);
      return;
    }
    if (type === "sources" || type === "citations") {
      mergeSources(assistant, event?.sources || event?.citations || []);
      return;
    }
    if (type === "done" || type === "complete" || type === "completed") {
      const message = event?.message || event?.response;
      const finalText = getMessageText(message);
      if (!assistant.content && finalText) assistant.content = finalText;
      mergeSources(assistant, event?.sources || message?.sources || message?.citations || []);
      return;
    }
    if (type === "error") {
      const streamError = new Error("Stream interrupted");
      streamError.status = Number(event?.status ?? event?.status_code) || undefined;
      streamError.detail = typeof event?.message === "string" ? event.message : "";
      streamError.retryAt = event?.retry_at ?? event?.retryAt ?? null;
      streamError.retryAfter = event?.retry_after ?? event?.retryAfter ?? null;
      throw streamError;
    }
    if (!type && typeof event?.text === "string") {
      assistant.content += event.text;
      updateStreamingMessage(index);
    }
  }

  async function submitMessage(providedContent) {
    const content = String(providedContent ?? dom.composerInput.value).trim();
    if (!content || state.sending) return;

    const userMessage = { role: "user", content, local: true };
    state.messages.push(userMessage);
    const assistant = { role: "assistant", content: "", sources: [], pending: true, local: true };
    state.messages.push(assistant);
    const assistantIndex = state.messages.length - 1;
    renderMessages();
    dom.composerInput.value = "";
    resizeComposer();
    state.shouldFollowStream = true;
    scrollToBottom(false);
    setSending(true);

    try {
      const chatId = await ensureChat(content);
      const controller = new AbortController();
      state.abortController = controller;
      const response = await fetch(`/api/chats/${encodeURIComponent(chatId)}/messages`, {
        method: "POST",
        headers: { Accept: "application/x-ndjson", "Content-Type": "application/json" },
        body: JSON.stringify({ content }),
        signal: controller.signal,
      });

      if (!response.ok) {
        throw await responseError(response, "Response interrupted");
      }
      if (!response.body) throw new Error("Response interrupted");

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop() || "";
        for (const rawLine of lines) {
          const line = rawLine.trim().replace(/^data:\s*/, "");
          if (!line || line === "[DONE]") continue;
          try {
            consumeStreamEvent(JSON.parse(line), assistant, assistantIndex);
          } catch (error) {
            if (error instanceof SyntaxError) continue;
            throw error;
          }
        }
      }
      const finalLine = buffer.trim().replace(/^data:\s*/, "");
      if (finalLine && finalLine !== "[DONE]") {
        try {
          consumeStreamEvent(JSON.parse(finalLine), assistant, assistantIndex);
        } catch (error) {
          if (!(error instanceof SyntaxError)) throw error;
        }
      }
      if (!assistant.content) throw new Error("Response interrupted");
      assistant.pending = false;
      assistant.local = false;
      renderMessages();
      scrollToBottom(false);
      await loadChats({ quiet: true });
    } catch (error) {
      assistant.pending = false;
      if (error?.name === "AbortError") {
        assistant.error = assistant.content ? "Stopped." : "Response stopped.";
      } else {
        assistant.error = friendlyError(error);
        loadStatus();
      }
      renderMessages();
      scrollToBottom(false);
    } finally {
      state.abortController = null;
      setSending(false);
    }
  }

  function setSending(sending) {
    state.sending = sending;
    dom.messages.setAttribute("aria-busy", String(sending));
    dom.sendButton.classList.toggle("is-stopping", sending);
    dom.sendButton.setAttribute("aria-label", sending ? "Stop response" : "Send message");
    dom.composerHint.textContent = sending ? "Tap to stop" : "Enter to send";
    updateSendButton();
  }

  function stopResponse() {
    if (!state.abortController) return;
    state.abortController.abort();
  }

  function updateSendButton() {
    dom.sendButton.disabled = state.sending ? false : !dom.composerInput.value.trim();
  }

  function resizeComposer() {
    dom.composerInput.style.height = "auto";
    dom.composerInput.style.height = `${Math.min(dom.composerInput.scrollHeight, 190)}px`;
    updateSendButton();
  }

  function isNearBottom() {
    return dom.chatScroll.scrollHeight - dom.chatScroll.scrollTop - dom.chatScroll.clientHeight < 110;
  }

  function scrollToBottom(smooth = true) {
    dom.chatScroll.scrollTo({
      top: dom.chatScroll.scrollHeight,
      behavior: smooth && !prefersReducedMotion() ? "smooth" : "auto",
    });
  }

  function handleScroll() {
    const nearBottom = isNearBottom();
    if (!state.sending || !nearBottom) state.shouldFollowStream = nearBottom;
    dom.jumpButton.hidden = nearBottom || state.messages.length === 0;
  }

  function syncSidebarAccessibility() {
    const mobile = window.matchMedia("(max-width: 900px)").matches;
    const open = dom.appShell.classList.contains("sidebar-open");
    dom.menuButton.setAttribute("aria-expanded", String(mobile && open));
    if (mobile) {
      dom.sidebar.inert = !open;
      dom.sidebar.setAttribute("aria-hidden", String(!open));
    } else {
      dom.sidebar.inert = false;
      dom.sidebar.removeAttribute("aria-hidden");
    }
  }

  function openSidebar() {
    dom.appShell.classList.add("sidebar-open");
    syncSidebarAccessibility();
    window.setTimeout(() => dom.newChatButton.focus(), 120);
  }

  function closeSidebar(restoreFocus = false) {
    const wasOpen = dom.appShell.classList.contains("sidebar-open");
    dom.appShell.classList.remove("sidebar-open");
    syncSidebarAccessibility();
    if (wasOpen && window.matchMedia("(max-width: 900px)").matches) {
      const focusTarget = restoreFocus ? dom.menuButton : dom.composerInput;
      window.setTimeout(() => focusTarget.focus({ preventScroll: true }), 80);
    }
  }

  function initializeVoiceInput() {
    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SpeechRecognition) {
      dom.voiceButton.hidden = true;
      return;
    }
    const recognition = new SpeechRecognition();
    dom.voiceButton.setAttribute("aria-pressed", "false");
    recognition.continuous = false;
    recognition.interimResults = true;
    recognition.lang = document.documentElement.lang || "en-US";
    let baseText = "";

    recognition.addEventListener("start", () => {
      state.listening = true;
      baseText = dom.composerInput.value.trim();
      dom.voiceButton.classList.add("is-listening");
      dom.voiceButton.setAttribute("aria-label", "Stop voice input");
      dom.voiceButton.setAttribute("aria-pressed", "true");
      dom.listeningState.hidden = false;
    });

    recognition.addEventListener("result", (event) => {
      const transcript = Array.from(event.results)
        .map((result) => result[0]?.transcript || "")
        .join("");
      dom.composerInput.value = `${baseText}${baseText && transcript ? " " : ""}${transcript}`;
      resizeComposer();
    });

    recognition.addEventListener("end", () => {
      state.listening = false;
      dom.voiceButton.classList.remove("is-listening");
      dom.voiceButton.setAttribute("aria-label", "Start voice input");
      dom.voiceButton.setAttribute("aria-pressed", "false");
      dom.listeningState.hidden = true;
      dom.composerInput.focus();
    });

    recognition.addEventListener("error", () => {
      showToast("Voice input is unavailable right now.");
    });

    state.recognition = recognition;
    dom.voiceButton.addEventListener("click", () => {
      if (state.listening) recognition.stop();
      else {
        try {
          recognition.start();
        } catch {
          showToast("Voice input is unavailable right now.");
        }
      }
    });
  }

  function bindEvents() {
    dom.sidebarThemeToggle.addEventListener("click", toggleTheme);
    dom.themeIconButton.addEventListener("click", toggleTheme);
    dom.menuButton.addEventListener("click", openSidebar);
    dom.sidebarClose.addEventListener("click", () => closeSidebar(true));
    dom.sidebarScrim.addEventListener("click", () => closeSidebar(true));
    dom.newChatButton.addEventListener("click", () => startNewChat());
    dom.historySearch.addEventListener("input", renderHistory);
    dom.jumpButton.addEventListener("click", () => scrollToBottom());
    dom.chatScroll.addEventListener("scroll", handleScroll, { passive: true });

    dom.composerInput.addEventListener("input", resizeComposer);
    dom.composerInput.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
        event.preventDefault();
        if (!state.sending) submitMessage();
      }
    });
    dom.composerForm.addEventListener("submit", (event) => {
      event.preventDefault();
      if (state.sending) stopResponse();
      else submitMessage();
    });

    document.querySelectorAll("[data-prompt]").forEach((button) => {
      button.addEventListener("click", () => {
        dom.composerInput.value = button.dataset.prompt || "";
        resizeComposer();
        dom.composerInput.focus();
      });
    });

    document.addEventListener("pointerdown", (event) => {
      if (state.activeMenu && !state.activeMenu.menu.contains(event.target) && !state.activeMenu.trigger.contains(event.target)) {
        closeChatMenu();
      }
    });

    document.addEventListener("keydown", (event) => {
      const modifier = event.metaKey || event.ctrlKey;
      if (modifier && event.key.toLowerCase() === "k") {
        event.preventDefault();
        if (window.innerWidth <= 900) openSidebar();
        window.setTimeout(() => dom.historySearch.focus(), 90);
      }
      if (event.key === "Escape") {
        if (state.listening) state.recognition?.stop();
        else if (state.activeMenu) closeChatMenu();
        else closeSidebar(true);
      }
    });

    window.addEventListener("resize", () => {
      closeChatMenu();
      if (window.innerWidth > 900) dom.appShell.classList.remove("sidebar-open");
      syncSidebarAccessibility();
    });
  }

  async function initialize() {
    initializeTheme();
    bindEvents();
    syncSidebarAccessibility();
    initializeVoiceInput();
    resizeComposer();
    await Promise.all([loadStatus(), loadChats()]);
    const hashMatch = location.hash.match(/^#chat=(.+)$/);
    if (hashMatch) {
      const id = decodeURIComponent(hashMatch[1]);
      if (state.chats.some((chat) => getChatId(chat) === id)) await openChat(id);
    }
  }

  initialize();
})();
