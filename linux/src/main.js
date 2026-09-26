// WeChatExporter Linux 前端（vanilla JS + Tauri v2 全局 API）

const invoke = (cmd, args = {}) => window.__TAURI__.core.invoke(cmd, args);

let contacts = [];
let selected = new Set();
let settings = null;

const $ = (id) => document.getElementById(id);

function log(msg) {
  const el = $("log");
  el.textContent += msg + "\n";
  el.scrollTop = el.scrollHeight;
}

function setStatus(s) { $("status-text").textContent = s; }

async function loadContacts() {
  const dir = $("data-dir").value.trim();
  if (!dir) { log("请先填写数据源目录"); return; }
  setStatus("加载中…");
  try {
    contacts = await invoke("load_contacts", { dataDir: dir });
    selected.clear();
    renderContacts();
    setStatus(`已加载 ${contacts.length} 个会话`);
    log(`已加载 ${contacts.length} 个会话`);
    // 记住数据目录到设置
    if (settings) { settings.export.dataDir = dir; }
  } catch (e) {
    setStatus("加载失败");
    log("加载失败：" + e);
  }
}

function renderContacts() {
  const q = $("contact-search").value.trim().toLowerCase();
  const list = $("contact-list");
  $("contact-count").textContent = `（${contacts.length}）`;
  if (!contacts.length) {
    list.innerHTML = '<p class="empty">未找到会话。请检查数据源目录结构。</p>';
    return;
  }
  const filtered = q
    ? contacts.filter((c) => [c.displayName, c.nickName, c.remark, c.id, c.summary].join(" ").toLowerCase().includes(q))
    : contacts;
  list.innerHTML = filtered
    .map((c) => {
      const kind = c.kind === "Group" ? "群聊" : c.kind === "Official" ? "公众号" : "好友";
      const sel = selected.has(c.id) ? " selected" : "";
      const time = c.lastTime ? c.lastTime : "";
      return `<div class="contact${sel}" data-id="${c.id}">
        <input type="checkbox" ${selected.has(c.id) ? "checked" : ""} />
        <div class="info">
          <div class="name">${esc(c.displayName)} <span class="badge">${kind}</span></div>
          <div class="meta">${esc(c.subtitle || "")}</div>
        </div>
      </div>`;
    })
    .join("");
  list.querySelectorAll(".contact").forEach((el) => {
    el.addEventListener("click", (ev) => {
      if (ev.target.tagName === "INPUT") return;
      const id = el.dataset.id;
      const cb = el.querySelector("input");
      if (selected.has(id)) { selected.delete(id); cb.checked = false; el.classList.remove("selected"); }
      else { selected.add(id); cb.checked = true; el.classList.add("selected"); }
    });
    el.querySelector("input").addEventListener("change", (ev) => {
      const id = el.dataset.id;
      if (ev.target.checked) { selected.add(id); el.classList.add("selected"); }
      else { selected.delete(id); el.classList.remove("selected"); }
    });
  });
}

async function doExport() {
  const dataDir = $("data-dir").value.trim();
  const outDir = $("export-dir").value.trim();
  if (!dataDir) { log("请先填写数据源目录"); return; }
  if (!outDir) { log("请先填写导出目录"); return; }
  if (!selected.size) { log("请先选择要导出的会话"); return; }

  $("btn-export").disabled = true;
  $("progress").classList.remove("hidden");
  $("summary").innerHTML = "";
  log("开始导出…");
  try {
    const summary = await invoke("export_contacts", {
      dataDir,
      outputDir: outDir,
      contactIds: Array.from(selected),
    });
    $("summary").innerHTML = (summary.lines || []).map((l) => `<div>${esc(l)}</div>`).join("");
    log(`导出完成：${summary.contacts} 个会话，共 ${summary.totalMessages} 条消息`);
    setStatus("导出完成");
  } catch (e) {
    $("summary").innerHTML = `<div class="err">${esc(String(e))}</div>`;
    log("导出失败：" + e);
    setStatus("导出失败");
  } finally {
    $("btn-export").disabled = false;
    $("progress").classList.add("hidden");
  }
}

async function openSettings() {
  await loadSettingsIntoForm();
  $("settings-overlay").classList.remove("hidden");
  refreshTimerStatus();
}

function loadSettingsIntoForm() {
  if (!settings) return;
  const e = settings.export;
  $("set-stats").checked = e.statsReport;
  $("set-index").checked = e.indexPage;
  $("set-search").checked = e.searchIndex;
  $("set-watermark").checked = e.watermarkEnabled;
  $("set-watermark-text").value = e.watermarkText;
  $("set-anon").checked = e.anon.enabled;
  $("set-anon-pii").checked = e.anon.maskPii;
  $("set-anon-keep").checked = e.anon.keepMapping;
  $("set-filter").checked = e.filter.enabled;
  $("set-filter-from").value = e.filter.fromDate;
  $("set-filter-to").value = e.filter.toDate;
  $("set-filter-kw").value = e.filter.keywords;
  $("set-annual").checked = e.annualReport;
  $("set-calendar").checked = e.calendarExtract;
  $("set-autosync-interval").value = e.autoSync.intervalMinutes;
}

async function saveSettingsFromForm() {
  if (!settings) return;
  const e = settings.export;
  e.statsReport = $("set-stats").checked;
  e.indexPage = $("set-index").checked;
  e.searchIndex = $("set-search").checked;
  e.watermarkEnabled = $("set-watermark").checked;
  e.watermarkText = $("set-watermark-text").value;
  e.anon.enabled = $("set-anon").checked;
  e.anon.maskPii = $("set-anon-pii").checked;
  e.anon.keepMapping = $("set-anon-keep").checked;
  e.filter.enabled = $("set-filter").checked;
  e.filter.fromDate = $("set-filter-from").value;
  e.filter.toDate = $("set-filter-to").value;
  e.filter.keywords = $("set-filter-kw").value;
  e.annualReport = $("set-annual").checked;
  e.calendarExtract = $("set-calendar").checked;
  e.autoSync.intervalMinutes = parseInt($("set-autosync-interval").value || "60", 10);
  e.dataDir = $("data-dir").value.trim() || e.dataDir;
  try {
    await invoke("save_settings", { settings });
    log("设置已保存");
    $("settings-overlay").classList.add("hidden");
  } catch (err) {
    log("保存设置失败：" + err);
  }
}

async function refreshTimerStatus() {
  try {
    $("timer-status").textContent = await invoke("timer_status");
  } catch (e) {
    $("timer-status").textContent = "（无法获取状态）";
  }
}

function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

async function init() {
  try {
    settings = await invoke("get_settings");
    const e = settings.export;
    if (e.dataDir) $("data-dir").value = e.dataDir;
    const home = (await invoke("get_settings"))?.export?.lastDir;
    $("export-dir").value = home || "~/Downloads/微信聊天记录导出";
    if (e.dataDir) {
      // 自动加载上次的数据目录
      log("检测到上次数据目录，自动加载…");
      await loadContacts();
    }
  } catch (e) {
    log("初始化失败：" + e);
  }

  // 绑定事件
  $("btn-load").addEventListener("click", loadContacts);
  $("btn-browse").addEventListener("click", async () => {
    const p = await invoke("pick_directory");
    if (p) { $("data-dir").value = p; loadContacts(); }
  });
  $("contact-search").addEventListener("input", renderContacts);
  $("btn-all").addEventListener("click", () => { contacts.forEach((c) => selected.add(c.id)); renderContacts(); });
  $("btn-none").addEventListener("click", () => { selected.clear(); renderContacts(); });
  $("btn-export").addEventListener("click", doExport);
  $("btn-settings").addEventListener("click", openSettings);
  $("btn-close-settings").addEventListener("click", () => $("settings-overlay").classList.add("hidden"));
  $("btn-save-settings").addEventListener("click", saveSettingsFromForm);
  $("btn-clear-log").addEventListener("click", () => { $("log").textContent = ""; });
  $("btn-install-timer").addEventListener("click", async () => {
    const interval = parseInt($("set-autosync-interval").value || "60", 10);
    const msg = await invoke("install_timer", { intervalMinutes: interval });
    log(msg);
    refreshTimerStatus();
  });
  $("btn-uninstall-timer").addEventListener("click", async () => {
    const msg = await invoke("uninstall_timer");
    log(msg);
    refreshTimerStatus();
  });

  // 进度日志事件
  window.__TAURI__.event.listen("wce:log", (e) => log(e.payload));
}

document.addEventListener("DOMContentLoaded", init);
