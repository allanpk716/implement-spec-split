"use strict";
// HTML renderer for the Progress board (ticket #13).  Pure functions: snapshot
// objects in, HTML strings out.  Every dynamic string goes through esc().

const EXTRA_CSS = `
    .meter-row { margin-top: 9px; }
    .meter-row .progress-label { margin-bottom: 4px; }
    .more { margin-top: 10px; background: transparent; box-shadow: none; overflow: visible; }
    .more > summary { min-height: 44px; justify-content: center; padding: 12px 15px; border-radius: 16px; background: var(--card); color: var(--blue); font-size: 14px; font-weight: 650; box-shadow: 0 1px 2px rgba(28,30,44,.04); }
    .more[open] > summary { margin-bottom: 10px; }
    .more .hint { color: var(--muted); font-size: 12px; text-align: center; margin: 4px 0 10px; }
    .count-card .pct { color: var(--blue); }
    .closed-node { display: flex; align-items: center; gap: 9px; min-height: 46px; padding: 11px 14px; border-radius: 17px; background: var(--card); box-shadow: 0 1px 2px rgba(28,30,44,.04); }
    .empty { margin: 8px; color: var(--muted); font-size: 13px; text-align: center; }
    .err-note { margin: 12px 0 0; padding: 9px 10px; border-radius: 11px; background: #fff6f2; color: #a33200; font-size: 13px; }
    .phone { overflow-x: hidden; }
    .cards { grid-template-columns: repeat(3, minmax(0,1fr)); }
    .count-card { min-width: 0; }
    .split span { overflow-wrap: anywhere; }
`;

const ESC = {"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"};
function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (ch) => ESC[ch]);
}

function pct(closed, total) {
  const t = Number(total), c = Number(closed);
  if (!Number.isFinite(t) || t <= 0 || !Number.isFinite(c)) return null;
  const value = Math.round((c * 100) / t);
  return c < t ? Math.min(99, value) : 100;
}
function pctText(closed, total) {
  const value = pct(closed, total);
  return value === null ? "—" : `${value}%`;
}

function repoSlug(repo) {
  const parts = String(repo).split("/");
  if (parts.length !== 2 || !parts.every((p) => /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(p))) return null;
  return parts;
}
function repoHref(repo, fromRepoPage) {
  const parts = repoSlug(repo);
  if (!parts) return null;
  return `${fromRepoPage ? "../../../" : ""}r/${encodeURIComponent(parts[0])}/${encodeURIComponent(parts[1])}/index.html`;
}

function fmtAbs(iso) {
  const d = new Date(iso);
  if (!Number.isFinite(d.getTime())) return "未知时间";
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}
function fmtDur(seconds) {
  if (!Number.isFinite(seconds)) return "?";
  if (seconds < 120) return `${seconds} 秒`;
  if (seconds < 7200) return `${Math.floor(seconds / 60)} 分钟`;
  return `${Math.floor(seconds / 3600)} 小时`;
}
function agoText(iso, nowEpoch) {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return "无活动";
  const s = Math.max(0, nowEpoch - Math.floor(t / 1000));
  if (s < 60) return `${s} 秒前`;
  if (s < 3600) return `${Math.floor(s / 60)} 分钟前`;
  if (s < 86400) return `${Math.floor(s / 3600)} 小时前`;
  return `${Math.floor(s / 86400)} 天前`;
}

const SCRIPT_COMMON = `
    (function () {
      var toast = document.getElementById('toast');
      function say(text) {
        toast.textContent = text; toast.classList.add('show');
        clearTimeout(window.__toastTimer);
        window.__toastTimer = setTimeout(function () { toast.classList.remove('show'); }, 1800);
      }
      document.getElementById('refresh').addEventListener('click', function () {
        var done = false;
        function fail() { if (!done) { done = true; say('刷新服务不可用'); } }
        try {
          fetch('/refresh', {method: 'POST'}).then(function (r) {
            if (r.ok) { done = true; say('已触发刷新'); } else { fail(); }
          }).catch(fail);
        } catch (e) { fail(); }
      });
      var stamp = document.getElementById('updated-at');
      function tick() {
        var t = Date.parse(stamp.getAttribute('data-snapshot-at'));
        if (isNaN(t)) return;
        var s = Math.max(0, Math.floor((Date.now() - t) / 1000));
        stamp.textContent = s < 60 ? s + ' 秒前更新' : s < 3600 ? Math.floor(s / 60) + ' 分钟前更新'
          : s < 86400 ? Math.floor(s / 3600) + ' 小时前更新' : Math.floor(s / 86400) + ' 天前更新';
      }
      tick(); setInterval(tick, 30000);
    })();
`;

function updatedSpan(snapshotAt) {
  return `<span id="updated-at" data-snapshot-at="${esc(snapshotAt)}">更新于 ${esc(fmtAbs(snapshotAt))}</span>`;
}

function page({title, css, body, snapshotAt}) {
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>${esc(title)}</title>
  <style>
${css}
${EXTRA_CSS}
  </style>
</head>
<body>
${body}
  <div class="toast" id="toast" role="status" aria-live="polite"></div>
  <script>${SCRIPT_COMMON}  </script>
</body>
</html>
`;
}

// ---------- shared next-wave text ----------
function nextWave(wave) {
  if (!wave) return {head: "不可用", items: [], note: "GitHub 关系图缺失"};
  const pick = (list) => list.map((i) => ({spec: i.spec, title: i.title}));
  if (wave.resume?.length) return {head: "先恢复", items: pick(wave.resume), note: "中断的 Spec 优先恢复"};
  if (wave.active?.length) return {head: "进行中", items: pick(wave.active), note: `${wave.active.length} 个实现中`};
  if (wave.wave1?.length) return {head: "第 1 波", items: pick(wave.wave1), note: "可启动"};
  return {head: "无可启动", items: [], note: "没有可启动的规格"};
}

function metricLine(c) {
  const mapsOpen = c.maps.total - c.maps.closed;
  const specsOpen = c.specs.total - c.specs.landed;
  const tickOpen = c.tickets.total - c.tickets.closed;
  return `<span class="metrics"><span>地图 已关 ${c.maps.closed}/${c.maps.total}（开 ${mapsOpen}）</span><span>Spec 已落 ${c.specs.landed}/${c.specs.total}（开 ${specsOpen}）</span><span>Ticket 已关 ${c.tickets.closed}/${c.tickets.total}（开 ${tickOpen}）</span></span>`;
}
function meterRow(label, closed, total) {
  const p = pct(closed, total);
  return `<span class="progress-wrap meter-row"><span class="progress-label"><span>${esc(label)}完成比例</span><b>${pctText(closed, total)}</b></span><span class="track"><span class="fill" style="width:${p === null ? 0 : p}%"></span></span></span>`;
}

// ---------- home ----------
function repoCard(r, nowEpoch, hidden) {
  const href = repoHref(r.repo, false);
  const open = href ? `<a class="repo-card${r.needs_attention ? " attention" : ""}" href="${esc(href)}" aria-label="查看 ${esc(r.repo)}">` : `<div class="repo-card${r.needs_attention ? " attention" : ""}">`;
  const close = href ? "</a>" : "</div>";
  const reasons = r.attention?.length
    ? `<span class="reason">${r.attention.map((a) => esc(`#${a.spec} ${a.detail}`)).join("<br>")}</span>` : "";
  let body;
  if (!r.counts) {
    body = `<span class="reason">计数不可用：${esc(r.error || "GitHub 关系图缺失")}</span>`;
  } else {
    const c = r.counts;
    body = `${metricLine(c)}${meterRow("地图", c.maps.closed, c.maps.total)}${meterRow("Spec", c.specs.landed, c.specs.total)}${meterRow("Ticket", c.tickets.closed, c.tickets.total)}`;
  }
  const nw = nextWave(r.next_wave);
  const items = nw.items.slice(0, 3).map((i) => `#${esc(i.spec)} ${esc(i.title)}`).join("<br>");
  const next = `<span class="next"><b>下一步</b><span>${items || esc(nw.head)}<small>${esc(items ? `${nw.head} · ${nw.note}` : nw.note)}</small></span><span class="chev">›</span></span>`;
  return `      ${open}
        <span class="repo-head"><span class="repo-name">${esc(r.repo)}<small>${r.last_activity ? `${esc(agoText(r.last_activity, nowEpoch))}活动` : "无活动"}</small></span>${r.needs_attention ? '<span class="badge">需处理</span>' : ""}</span>
        ${reasons}${body}${next}
      ${close}`;
}

// sel = {attention: [], recent: [], hidden: [], unused: n}
function renderHome(sel, ctx) {
  const {snapshotAt, nowEpoch} = ctx;
  const css = ctx.homeCss ?? HOME_CSS;
  const stack = (list) => `<div class="stack">\n${list.map((r) => repoCard(r, nowEpoch)).join("\n")}\n    </div>`;
  const parts = [];
  if (sel.attention.length) parts.push(`    <p class="section-label">需要处理</p>\n    ${stack(sel.attention)}`);
  if (sel.recent.length) parts.push(`    <p class="section-label">${sel.attention.length ? "按最近活动" : "近期活动"}</p>\n    ${stack(sel.recent)}`);
  if (!sel.attention.length && !sel.recent.length) parts.push('    <p class="empty">没有符合条件的仓库。</p>');
  if (sel.hidden.length) {
    parts.push(`    <details class="more">
      <summary>显示全部（另有 ${sel.hidden.length} 个）</summary>
      <p class="section-label" style="margin-top:6px">安静仓库</p>
      ${stack(sel.hidden)}
    </details>`);
  }
  const shown = sel.attention.length + sel.recent.length;
  const body = `  <div class="phone" id="board">
    <header class="topbar">
      <div class="top-row">
        <div>
          <h1>管线进度</h1>
          <div class="sub">${updatedSpan(snapshotAt)} · 默认显示 ${shown} / ${shown + sel.hidden.length}</div>
        </div>
        <button class="refresh" type="button" id="refresh">立即刷新</button>
      </div>
    </header>
${parts.join("\n\n")}
    <footer>只读进度板 · 数据快照 ${esc(fmtAbs(snapshotAt))}${sel.unused ? ` · 另有未使用仓库 ${sel.unused} 个` : ""}</footer>
  </div>`;
  return page({title: "管线进度 · 卡片", css, body, snapshotAt});
}

// ---------- repo ----------
const MAP_LABEL = {closed: "关", converted: "已转", fog_pending: "迷雾", unconverted: "未转", exploring: "探索", empty: "空", shelved: "搁置"};
const SPEC_LABEL = {landed: "落地", running: "实现中", ready: "待做", needs_tickets: "没拆票", interrupted: "中断", shelved: "搁置"};
const PHASES = ["split", "implement", "integrate", "review", "land"];

function leaf(text, small) {
  return `<div class="leaf"><span>${text}</span>${small ? `<small>${esc(small)}</small>` : ""}</div>`;
}
function ticketLeaves(tickets) {
  const open = tickets.filter((t) => t.state !== "closed");
  const closed = tickets.length - open.length;
  const out = open.map((t) => leaf(esc(`#${t.number} ${t.title}`), t.shelved ? "搁置" : "待做"));
  if (closed) out.push(leaf(`已关 Ticket ${closed} 张`, `${closed}/${tickets.length}`));
  return out;
}
function workerHtml(w) {
  const bad = w.anomalous;
  const status = w.status || w.state;
  const cls = bad ? (w.state === "running" ? "worker-stalled" : "worker-error") : "";
  const pill = bad ? (w.state === "running" ? "s-stalled" : "s-error") : (w.state === "running" ? "s-running" : "");
  return `<details class="worker ${cls}"${bad ? " open" : ""}>
                  <summary><span class="caret">▶</span><span class="node-title"><b>${esc(w.name)}</b><span>${esc(w.role)} · ${esc(fmtDur(w.duration_s))} · ${bad ? "异常" : "正常"}</span></span><span class="status ${pill}">${esc(status)}</span></summary>
                  <div class="worker-body">角色 ${esc(w.role)} · Ticket ${w.ticket == null ? "?" : `#${esc(w.ticket)}`} · 状态 ${esc(w.state)}${w.status ? `/${esc(w.status)}` : ""} · 已运行 ${esc(fmtDur(w.duration_s))}，距上次活动 ${esc(fmtDur(w.idle_s))}${bad ? ` · ${esc(w.anomaly_reason)}` : ""}</div>
                </details>`;
}
function runCard(spec) {
  const run = spec.run;
  const claim = spec.claim;
  const idx = run ? PHASES.indexOf(run.phase) : -1;
  const t = run?.tickets;
  const total = t ? (t.merged || 0) + (t.in_progress || 0) + (t.todo || 0) : 0;
  const stages = run ? `<div class="stages">${PHASES.map((p, i) => `<span class="stage${i < idx ? " complete" : i === idx ? " current" : ""}"><i></i><em>${p}</em></span>`).join("")}</div>` : "";
  const meter = t && total ? `<div class="ticket-meter" title="merged ${esc(t.merged)} / in progress ${esc(t.in_progress)} / todo ${esc(t.todo)}"><i style="flex:${Number(t.merged) || 0}"></i><i class="progress" style="flex:${Number(t.in_progress) || 0}"></i><i class="todo" style="flex:${Number(t.todo) || 0}"></i></div><div class="meter-note"><span>Run：已合 ${esc(t.merged)} · 进行中 ${esc(t.in_progress)} · 待做 ${esc(t.todo)}</span></div>` : "";
  return `<div class="stage-card"><div class="stage-top"><span>Run 阶段 <b>${esc(run?.phase || "无 Run")}</b>${run?.wave ? ` · 第 ${esc(run.wave)} 波` : ""}</span><span>claim <b>${esc(claim?.state || "无")}</b></span></div>${stages}${meter}</div>`;
}
function specHtml(spec) {
  const run = spec.run, t = run?.tickets;
  const merged = t ? `Run 已合 ${t.merged ?? 0}/${(t.merged || 0) + (t.in_progress || 0) + (t.todo || 0)}` : `Ticket 已关 ${spec.tickets_closed}/${spec.tickets_total}`;
  const sub = [spec.claim ? `claim ${spec.claim.state}` : (SPEC_LABEL[spec.status] || spec.status), run ? run.phase : null, run?.wave ? `wave ${run.wave}` : null, merged].filter(Boolean).join(" · ");
  const label = spec.claim?.state || spec.status;
  const pill = spec.claim?.state === "interrupted" ? "interrupted" : spec.claim ? "status s-active" : "needs";
  const inner = [];
  if (spec.run || spec.claim) inner.push(runCard(spec));
  if (!spec.tickets.length) inner.push(leaf("尚未拆分 Ticket", "等待拆票"));
  else inner.push(...ticketLeaves(spec.tickets));
  for (const w of spec.workers || []) inner.push(workerHtml(w));
  const open = spec.claim || spec.run || (spec.workers || []).some((w) => w.anomalous);
  return `<details class="child"${open ? " open" : ""}>
              <summary><span class="caret">▶</span><span class="node-title"><b>${esc(`Spec #${spec.number} · ${spec.title}`)}</b><span>${esc(sub)}</span></span><span class="${pill}">${esc(SPEC_LABEL[label] || label)}</span></summary>
              <div class="inner">
                ${inner.join("\n                ")}
              </div>
            </details>`;
}
function specGroup(specs) {
  const closed = specs.filter((s) => s.state === "closed");
  const open = specs.filter((s) => s.state !== "closed");
  const out = open.map(specHtml);
  if (closed.length) {
    const tc = closed.reduce((a, s) => a + (s.tickets_closed || 0), 0);
    const tt = closed.reduce((a, s) => a + (s.tickets_total || 0), 0);
    out.push(leaf(`已落地 Spec ${closed.length} 份`, `${tc}/${tt} Ticket`));
  }
  return out;
}

function renderRepo(snap, ctx) {
  const {nowEpoch} = ctx;
  const css = ctx.repoCss ?? REPO_CSS;
  const c = snap.counts;
  const back = `<a class="back" href="../../../index.html" aria-label="返回首页">‹</a>`;
  let counts;
  if (!c) {
    counts = `<div class="err-note">计数不可用：${esc(snap.error || "GitHub 关系图缺失")}</div>`;
  } else {
    const m = c.maps, s = c.specs, tk = c.tickets;
    const card = (name, total, unit, closed, rows) => `<article class="count-card">
          <h2>${name}</h2><strong>${esc(total)}<small> ${unit}</small></strong>
          <div class="split">${rows.map(([k, v]) => `<span>${k} <b>${esc(v)}</b></span>`).join("")}<span>完成 <b class="pct">${pctText(closed, total)}</b></span></div>
        </article>`;
    counts = `<div class="cards">
        ${card("地图", m.total, "张", m.closed, [["已关", m.closed], ["开 · 探索", m.exploring], ["开 · 迷雾待毕业", m.fog_pending], ["开 · 未转 Spec", m.unconverted]])}
        ${card("Spec", s.total, "份", s.landed, [["已落地", s.landed], ["没拆 Ticket", s.needs_tickets], ["已拆待做", s.ready], ["实现中", s.running], ["中断", s.interrupted]])}
        ${card("Ticket", tk.total, "张", tk.closed, [["已关", tk.closed], ["未关", tk.total - tk.closed]])}
      </div>`;
  }
  const nw = nextWave(snap.next_wave);
  const nextBody = nw.items.length
    ? nw.items.map((i) => `<div class="next-head"><h2>${esc(`#${i.spec} ${i.title}`)}</h2><span class="pill">${esc(nw.head)}</span></div>`).join("")
    : `<div class="next-head"><h2>${esc(nw.head)}</h2></div>`;
  const attention = snap.attention?.length
    ? `<p class="meta" style="color:#a33200">${snap.attention.map((a) => esc(`#${a.spec} ${a.detail}`)).join("<br>")}</p>` : "";

  const maps = snap.maps.map((map) => {
    const label = map.shelved ? "搁置" : (MAP_LABEL[map.status] || map.status);
    if (map.state === "closed") {
      const tk = map.specs.reduce((a, s) => a + (s.tickets_total || 0), 0) + map.tickets.length;
      return `<div class="closed-node"><span class="node-title"><b>${esc(`地图 #${map.number} · ${map.title}`)}</b><span>已关闭 · ${map.specs.length} Spec · ${tk} Ticket</span></span><span class="state closed">${esc(label)}</span></div>`;
    }
    const inner = [...specGroup(map.specs), ...ticketLeaves(map.tickets)];
    if (!inner.length) inner.push(leaf("还没有 Spec", "未转 Spec"));
    const tk = map.specs.reduce((a, s) => a + (s.tickets_total || 0), 0) + map.tickets.length;
    return `<details open>
          <summary><span class="caret">▶</span><span class="node-title"><b>${esc(`地图 #${map.number} · ${map.title}`)}</b><span>开着 · ${map.specs.length} Spec · ${tk} Ticket</span></span><span class="state ${map.status === "fog_pending" || map.status === "unconverted" ? "needs" : "open"}">${esc(label)}</span></summary>
          <div class="inner">
            ${inner.join("\n            ")}
          </div>
        </details>`;
  });
  const tree = maps.length ? maps.join("\n        ") : '<p class="empty">没有地图</p>';
  const loose = snap.loose_specs?.length ? `
    <section aria-label="散 Spec">
      <div class="tree-title">散 Spec（不属于地图）</div>
      <div class="tree">
        <div class="loose-group">
        ${specGroup(snap.loose_specs).join("\n        ")}
        </div>
      </div>
    </section>` : "";
  const gh = snap.github_error ? `<div class="err-note">GitHub 刷新失败：${esc(snap.github_error)}（沿用旧缓存）</div>` : "";

  const body = `  <div class="phone">
    <header class="topbar">
      ${back}
      <div class="title">
        <h1>${esc(snap.repo)}</h1>
        <p>${updatedSpan(snap.snapshot_at)}${snap.needs_attention ? " · 需要处理" : ""}</p>
      </div>
      <button class="refresh" type="button" id="refresh">立即刷新</button>
    </header>
    ${gh}
    <section aria-label="总览">
      <div class="group-label">三类计数</div>
      ${counts}
    </section>

    <section aria-label="下一波起点">
      <div class="group-label">下一波起点</div>
      <div class="card pad${snap.needs_attention ? " attention" : ""}">
        ${nextBody}
        <p class="meta">${esc(nw.note)}</p>
        ${attention}
      </div>
    </section>

    <section aria-label="管线树">
      <div class="tree-title">地图 → Spec → Ticket</div>
      <div class="tree">
        ${tree}
      </div>
    </section>
${loose}
    <footer>只读进度板 · 数据快照 ${esc(fmtAbs(snap.snapshot_at))}</footer>
  </div>`;
  return page({title: `${snap.repo} · 管线进度`, css, body, snapshotAt: snap.snapshot_at});
}

const HOME_CSS = `
    :root {
      color-scheme: light;
      --bg: #f2f2f7;
      --card: #ffffff;
      --ink: #111111;
      --muted: #6d6d78;
      --faint: #8e8e96;
      --line: rgba(60, 60, 67, .12);
      --blue: #007aff;
      --green: #34c759;
      --orange: #ff9500;
      --red: #ff3b30;
      --fill: #eef0f4;
    }
    * { box-sizing: border-box; }
    html { -webkit-text-size-adjust: 100%; }
    body {
      margin: 0;
      min-height: 100vh;
      background: var(--bg);
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
      font-size: 15px;
      line-height: 1.45;
      letter-spacing: -.01em;
    }
    .phone { max-width: 430px; margin: 0 auto; padding: 0 14px calc(28px + env(safe-area-inset-bottom)); }
    .topbar {
      position: sticky;
      top: 0;
      z-index: 5;
      margin: 0 -14px;
      padding: calc(10px + env(safe-area-inset-top)) 16px 10px;
      background: rgba(242, 242, 247, .92);
      border-bottom: 1px solid rgba(60, 60, 67, .10);
      backdrop-filter: saturate(180%) blur(18px);
      -webkit-backdrop-filter: saturate(180%) blur(18px);
    }
    .top-row { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
    h1 { margin: 0; font-size: 27px; line-height: 1.15; letter-spacing: -.035em; }
    .sub { margin-top: 3px; color: var(--muted); font-size: 13px; }
    .refresh {
      flex: 0 0 auto;
      min-height: 40px;
      padding: 9px 13px;
      border: 0;
      border-radius: 13px;
      background: var(--blue);
      color: #fff;
      font: 600 14px/1 inherit;
      font-family: inherit;
      cursor: pointer;
    }
    .refresh:active { transform: scale(.97); }
    .section-label {
      margin: 22px 8px 8px;
      color: var(--muted);
      font-size: 13px;
      font-weight: 650;
      text-transform: uppercase;
      letter-spacing: .02em;
    }
    .stack { display: grid; gap: 10px; }
    .repo-card {
      position: relative;
      display: block;
      overflow: hidden;
      padding: 15px 15px 14px 17px;
      border-radius: 18px;
      background: var(--card);
      color: inherit;
      text-decoration: none;
      box-shadow: 0 1px 2px rgba(28, 30, 44, .05);
    }
    .repo-card:active { background: #f8f8fb; }
    .repo-card::before {
      content: "";
      position: absolute;
      left: 0; top: 10px; bottom: 10px;
      width: 4px;
      border-radius: 0 4px 4px 0;
      background: transparent;
    }
    .repo-card.attention::before { background: linear-gradient(180deg, var(--orange), var(--red)); }
    .repo-head { display: flex; align-items: start; justify-content: space-between; gap: 10px; }
    .repo-name { min-width: 0; font-size: 17px; font-weight: 700; letter-spacing: -.025em; overflow-wrap: anywhere; }
    .repo-name small { display: block; margin-top: 2px; color: var(--muted); font-size: 12px; font-weight: 500; letter-spacing: 0; }
    .badge {
      flex: 0 0 auto;
      margin-top: 2px;
      padding: 4px 8px;
      border-radius: 999px;
      background: #fff1e8;
      color: #b33a00;
      font-size: 12px;
      font-weight: 700;
      white-space: nowrap;
    }
    .reason {
      margin: 10px 0 0;
      padding: 9px 10px;
      border-radius: 11px;
      background: #fff6f2;
      color: #a33200;
      font-size: 13px;
    }
    .reason strong { display: block; margin-bottom: 2px; }
    .metrics {
      display: flex;
      flex-wrap: wrap;
      gap: 5px 6px;
      margin-top: 12px;
      color: var(--muted);
      font-size: 12px;
      font-variant-numeric: tabular-nums;
    }
    .metrics span { padding: 3px 7px; border-radius: 8px; background: var(--fill); white-space: nowrap; }
    .metrics b { color: var(--ink); font-weight: 650; }
    .progress-wrap, .track, .reason, .metrics { display: block; }
    .metrics { display: flex; }
    .progress-wrap { margin-top: 13px; }
    .progress-label { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; color: var(--muted); font-size: 12px; }
    .progress-label b { color: var(--ink); font-weight: 650; }
    .track { height: 6px; border-radius: 99px; background: var(--fill); overflow: hidden; }
    .fill { display: block; height: 100%; border-radius: 99px; background: linear-gradient(90deg, #33c77a, #24a35b); }
    .next {
      display: flex;
      gap: 8px;
      margin-top: 13px;
      padding-top: 11px;
      border-top: 1px solid var(--line);
      color: var(--muted);
      font-size: 13px;
    }
    .next b { flex: 0 0 auto; color: #0a6ccb; font-weight: 700; }
    .next div, .next > span:not(.chev) { min-width: 0; color: var(--ink); }
    .next div small, .next > span:not(.chev) small { display: block; color: var(--faint); font-size: 12px; }
    .chev { flex: 0 0 auto; margin-left: auto; align-self: center; color: #c5c5cc; font-size: 19px; }
    .hidden-card { display: none; }
    .show-all {
      display: block;
      min-height: 44px;
      margin-top: 1px;
      padding: 12px 15px;
      border-radius: 16px;
      background: var(--card);
      color: var(--blue);
      font-size: 14px;
      font-weight: 650;
      text-align: center;
      text-decoration: none;
      box-shadow: 0 1px 2px rgba(28, 30, 44, .04);
    }
    .expanded .show-all { display: none; }
    footer { margin-top: 20px; color: var(--faint); font-size: 12px; text-align: center; }
    .toast {
      position: fixed;
      left: 50%;
      bottom: calc(26px + env(safe-area-inset-bottom));
      z-index: 20;
      padding: 11px 17px;
      border-radius: 99px;
      background: rgba(28, 30, 44, .92);
      color: white;
      font-size: 14px;
      font-weight: 600;
      transform: translate(-50%, 18px);
      opacity: 0;
      pointer-events: none;
      transition: .22s ease;
    }
    .toast.show { transform: translate(-50%, 0); opacity: 1; }
`;
const REPO_CSS = `
    :root {
      color-scheme: light;
      --bg: #f2f2f7;
      --card: #fff;
      --ink: #111;
      --muted: #6d6d78;
      --faint: #8e8e96;
      --line: rgba(60,60,67,.11);
      --blue: #007aff;
      --green: #34c759;
      --orange: #ff9500;
      --red: #ff3b30;
      --track: #e9ebf0;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
      font-size: 15px;
      line-height: 1.45;
      letter-spacing: -.01em;
    }
    .phone { max-width: 430px; margin: 0 auto; padding: 0 14px calc(30px + env(safe-area-inset-bottom)); }
    .topbar {
      position: sticky; top: 0; z-index: 5;
      margin: 0 -14px;
      padding: calc(8px + env(safe-area-inset-top)) 12px 8px 8px;
      background: rgba(242,242,247,.92);
      border-bottom: 1px solid rgba(60,60,67,.09);
      backdrop-filter: saturate(180%) blur(18px);
      -webkit-backdrop-filter: saturate(180%) blur(18px);
      display: flex; align-items: center; gap: 6px;
    }
    .back {
      min-width: 42px; min-height: 40px;
      display: inline-flex; align-items: center; justify-content: center;
      border-radius: 12px; color: var(--blue); font-size: 25px; text-decoration: none;
    }
    .title { min-width: 0; margin-right: auto; }
    .title h1 { margin: 0; font-size: 18px; line-height: 1.2; letter-spacing: -.025em; overflow-wrap: anywhere; }
    .title p { margin: 1px 0 0; color: var(--muted); font-size: 12px; }
    .refresh {
      min-height: 40px; padding: 9px 12px; border: 0; border-radius: 12px;
      background: var(--blue); color: white; font-family: inherit; font-size: 13px; font-weight: 650; cursor: pointer;
    }
    .group-label { margin: 20px 8px 7px; color: var(--muted); font-size: 13px; font-weight: 650; }
    .cards { display: grid; grid-template-columns: repeat(3, minmax(0,1fr)); gap: 8px; }
    .count-card { padding: 12px 11px; border-radius: 16px; background: var(--card); box-shadow: 0 1px 2px rgba(28,30,44,.04); }
    .count-card h2 { margin: 0; color: var(--muted); font-size: 12px; }
    .count-card strong { display: block; margin: 3px 0 6px; font-size: 24px; line-height: 1; letter-spacing: -.035em; }
    .count-card strong small { color: var(--muted); font-size: 12px; font-weight: 600; }
    .split { display: grid; gap: 3px; color: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
    .split b { color: var(--ink); font-weight: 650; }
    .card { border-radius: 18px; background: var(--card); box-shadow: 0 1px 2px rgba(28,30,44,.04); overflow: hidden; }
    .pad { padding: 14px 15px; }
    .attention { border-left: 4px solid; border-image: linear-gradient(#ff9500,#ff3b30) 1; background: #fffaf8; }
    .next-head { display: flex; justify-content: space-between; align-items: start; gap: 8px; }
    .next-head h2 { margin: 0; font-size: 16px; line-height: 1.3; overflow-wrap: anywhere; }
    .pill { flex: 0 0 auto; padding: 4px 8px; border-radius: 99px; background: #e8f1ff; color: #0a6ccb; font-size: 12px; font-weight: 700; }
    .meta { margin-top: 8px; color: var(--muted); font-size: 12px; }
    details { background: var(--card); border-radius: 17px; box-shadow: 0 1px 2px rgba(28,30,44,.04); overflow: hidden; }
    summary {
      min-height: 46px; padding: 11px 14px; cursor: pointer; list-style: none;
      display: flex; align-items: center; gap: 9px; user-select: none; -webkit-tap-highlight-color: transparent;
    }
    summary::-webkit-details-marker { display: none; }
    summary:active { background: #f6f6f9; }
    .caret { color: #b9b9c1; font-size: 13px; transition: transform .15s; }
    details[open] > summary .caret { transform: rotate(90deg); }
    .node-title { min-width: 0; flex: 1; }
    .node-title b { display: block; font-size: 15px; line-height: 1.25; font-weight: 650; overflow-wrap: anywhere; }
    .node-title span { display: block; margin-top: 2px; color: var(--muted); font-size: 12px; }
    .state { flex: 0 0 auto; font-size: 12px; font-weight: 700; white-space: nowrap; }
    .closed { color: #6a7480; }
    .running { color: #0a6ccb; }
    .interrupted { color: #c22b20; }
    .needs { color: #9a5b00; }
    .open { color: #177c39; }
    .inner { border-top: 1px solid var(--line); padding: 3px 10px 10px 12px; }
    .child { margin-top: 7px; border-radius: 13px; background: #f7f7fa; box-shadow: none; }
    .child summary { padding: 10px 11px; min-height: 42px; }
    .child .inner { padding: 2px 8px 8px 9px; border-top: 1px solid var(--line); }
    .leaf {
      display: flex; align-items: center; gap: 7px; min-height: 42px;
      margin-top: 6px; padding: 9px 10px; border-radius: 11px; background: white;
      color: inherit; text-decoration: none; box-shadow: 0 0 0 1px var(--line);
    }
    .leaf span { min-width: 0; flex: 1; overflow-wrap: anywhere; font-size: 13px; }
    .leaf small { flex: 0 0 auto; color: var(--muted); font-size: 11px; white-space: nowrap; }
    .done { color: #6d6d78; }
    .stage-card { margin: 7px 0; padding: 12px; border-radius: 13px; background: white; box-shadow: 0 0 0 1px var(--line); }
    .stage-top { display: flex; justify-content: space-between; gap: 8px; color: var(--muted); font-size: 12px; }
    .stage-top b { color: var(--ink); }
    .stages { display: grid; grid-template-columns: repeat(5,minmax(0,1fr)); gap: 3px; margin-top: 10px; }
    .stage { min-width: 0; text-align: center; }
    .stage i { display: block; height: 5px; border-radius: 99px; background: var(--track); }
    .stage em { display: block; margin-top: 5px; color: var(--faint); font-size: 10px; font-style: normal; white-space: nowrap; }
    .stage.complete i { background: #9fd8b2; }
    .stage.complete em { color: #177c39; }
    .stage.current i { background: linear-gradient(90deg,#ff9500,#ff6a00); }
    .stage.current em { color: #a34c00; font-weight: 800; }
    .ticket-meter { display: flex; gap: 4px; margin-top: 10px; height: 6px; }
    .ticket-meter i { display: block; flex: 3; border-radius: 99px; background: #34c759; }
    .ticket-meter i.progress { flex: 1; background: #007aff; }
    .ticket-meter i.todo { flex: 2; background: #d8dce3; }
    .meter-note { display: flex; justify-content: space-between; margin-top: 6px; color: var(--muted); font-size: 11px; }
    .worker { margin-top: 7px; border-radius: 12px; background: white; box-shadow: 0 0 0 1px var(--line); overflow: hidden; }
    .worker summary { padding: 10px 11px; min-height: 42px; }
    .worker-error summary { background: #fff4f2; }
    .worker-stalled summary { background: #fff7ed; }
    .worker-body { padding: 9px 11px 11px; border-top: 1px solid var(--line); color: var(--muted); font-size: 12px; }
    .status { padding: 3px 7px; border-radius: 99px; font-size: 11px; font-weight: 800; }
    .s-error { background: #ffe3df; color: #bf2016; }
    .s-running { background: #e8f1ff; color: #0a6ccb; }
    .s-stalled { background: #ffedd5; color: #a34c00; }
    .s-active { background: #e8f1ff; color: #0a6ccb; }
    .tree-title { margin: 22px 8px 8px; color: var(--muted); font-size: 13px; font-weight: 650; }
    .tree { display: grid; gap: 9px; }
    .loose { border-top: 6px solid #e4e6eb; }
    footer { margin-top: 20px; color: var(--faint); font-size: 12px; text-align: center; }
    .toast {
      position: fixed; left: 50%; bottom: calc(26px + env(safe-area-inset-bottom)); z-index: 20;
      padding: 11px 17px; border-radius: 99px; background: rgba(28,30,44,.92); color: white;
      font-size: 14px; font-weight: 650; transform: translate(-50%,18px); opacity: 0; pointer-events: none; transition: .2s;
    }
    .toast.show { transform: translate(-50%,0); opacity: 1; }
    @media (max-width:370px) { .cards { grid-template-columns: 1fr; } .stage em { font-size: 9px; } }
`;

module.exports = {renderHome, renderRepo, repoSlug, esc, pct};
