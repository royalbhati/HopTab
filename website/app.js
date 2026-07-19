// HopTab landing page — vanilla JS (no framework).

// --- X (Twitter) Ads pixel. Set the pixel ID from ads.x.com → Tools → Events
// Manager to activate; empty string = pixel never loads.
var X_PIXEL_ID = "";
if (X_PIXEL_ID) {
  !function(e,t,n,s,u,a){e.twq||(s=e.twq=function(){s.exe?s.exe.apply(s,arguments):s.queue.push(arguments);},
  s.version='1.1',s.queue=[],u=t.createElement(n),u.async=!0,u.src='https://static.ads-twitter.com/uwt.js',
  a=t.getElementsByTagName(n)[0],a.parentNode.insertBefore(u,a))}(window,document,'script');
  twq('config', X_PIXEL_ID);
}

// --- Analytics: fire a custom event into whatever providers are loaded.
// Safe no-op if a provider hasn't loaded or is blocked by the browser.
window.track = function (event, data) {
  data = data || {};
  try { if (window.umami && window.umami.track) window.umami.track(event, data); } catch (e) {}
  try { if (window.gtag) window.gtag("event", event, data); } catch (e) {}
  try {
    if (window.twq && event === "download_click") twq("event", "tw-download", {});
    if (window.twq && event === "pro_click") twq("event", "tw-pro-click", {});
  } catch (e) {}
};

// --- Workflows (interactive tabs) ---------------------------------------
var workflows = [
  {
    title: "Morning Coding Setup", role: "Developer", pro: false,
    desc: "You open your laptop, swipe to Desktop 2. HopTab auto-switches to your “Coding” profile. Your pinned apps — Zed, Wezterm, Chrome, TablePlus — are ready. You press one button and all four snap into an IDE layout: editor 60% left, terminal top-right, browser bottom-right. You’re coding in under 5 seconds.",
    steps: [
      { title: "Swipe to Desktop 2", desc: "Profile auto-switches to “Coding”" },
      { title: "Apply layout", desc: "IDE 60/40 — all 4 apps snap to zones" },
      { title: "⌥+Tab to switch", desc: "Cycle only between pinned dev apps" },
      { title: "⌃⌥+← to snap", desc: "Move any window — sizes cycle on repeat" }
    ]
  },
  {
    title: "Deep Research Session", role: "PM / Researcher", pro: false,
    desc: "You’re comparing three sources. Snap Chrome to the left third, Notion to the center third, Obsidian to the right third. Switch to a doc — ⌥+Tab jumps to Notion instantly. Need to check Slack? It’s not pinned, so it stays out of your way. When you’re done, save the session — tomorrow you restore everything exactly as it was.",
    steps: [
      { title: "Three-column layout", desc: "Chrome | Notion | Obsidian side by side" },
      { title: "Pin only what matters", desc: "Slack, Mail, Calendar stay out of your flow" },
      { title: "Save session", desc: "Every window position + size saved per profile" },
      { title: "Restore tomorrow", desc: "One click — all windows back exactly where they were" }
    ]
  },
  {
    title: "Dual Monitor Design Review", role: "Designer", pro: false,
    desc: "Figma on the external display, Xcode on the laptop. You’re comparing the design to your implementation. Snap Figma to full on monitor 2, Xcode left-half on monitor 1, Simulator right-half. Need to move a window? ⌃⌥⌘+→ throws it to the other display.",
    steps: [
      { title: "Pin Figma + Xcode + Simulator", desc: "Three-app “Design Review” profile" },
      { title: "Snap across monitors", desc: "Figma full on external, Xcode split on laptop" },
      { title: "Move windows between displays", desc: "⌃⌥⌘+Arrow to throw" },
      { title: "Per-profile hotkey", desc: "Jump back to “Coding” profile instantly" }
    ]
  },
  {
    title: "Interrupt-Driven Workday", role: "Anyone", pro: false,
    desc: "You’re deep in code. A Slack DM pulls you into a support thread. You press your “Support” profile hotkey — HopTab saves your coding session, switches to the Support profile (Slack, Zendesk, Chrome), and applies its layout. Press the “Coding” hotkey — everything restores instantly.",
    steps: [
      { title: "Coding — deep focus", desc: "Zed + Terminal + Browser, IDE layout applied" },
      { title: "Interrupt arrives", desc: "Press Support profile hotkey" },
      { title: "Session saved + switched", desc: "Coding windows saved, Support apps appear" },
      { title: "Back to code", desc: "Coding hotkey restores everything instantly" }
    ]
  },
  {
    title: "Meeting-Aware Workday", role: "Pro", pro: true,
    desc: "Your calendar has “Daily Standup” at 10 AM. Two minutes before, HopTab shows a fullscreen reminder with a countdown and a “Join Meeting” button that opens your Zoom link. It auto-switches to your Meeting profile. When the meeting ends, it switches back to Coding.",
    steps: [
      { title: "Map “Standup” to Meeting profile", desc: "One-time setup in Profiles → Calendar" },
      { title: "9:58 AM — reminder appears", desc: "Fullscreen countdown + Join button" },
      { title: "Click Join — Zoom opens", desc: "Profile switches to Meeting automatically" },
      { title: "Meeting ends — back to Coding", desc: "Previous profile restored automatically" }
    ]
  },
  {
    title: "Dock-Aware Developer", role: "Pro", pro: true,
    desc: "At the office, you dock your MacBook to an external monitor. HopTab detects the display change and switches to your “Docked” profile. You unplug at 6 PM and it switches to “Laptop”. At 7 PM, the time schedule kicks in and switches to Entertainment. Zero manual switching all day.",
    steps: [
      { title: "Plug in monitor", desc: "Display auto-profile activates “Docked”" },
      { title: "Work all day", desc: "Time tracking logs hours per profile" },
      { title: "Unplug at 6 PM", desc: "“Laptop” profile takes over" },
      { title: "7 PM — schedule triggers", desc: "Entertainment profile activates automatically" }
    ]
  },
  {
    title: "Focus Sprint on a Task", role: "Pro", pro: true,
    desc: "“Write the Q3 doc” is blocked on your calendar at 2 PM. You open the event in HopTab and hit the timer. A 25-minute focus interval starts; when it ends, a full-screen break nudges you to look away, then the next interval begins. Every minute you focus logs straight back to that event, so by Friday you know the doc actually cost you 3h 10m.",
    steps: [
      { title: "Open the event", desc: "Hit the timer to start a Pomodoro tied to it" },
      { title: "25 / 5 cycle runs", desc: "Work, then a break overlay; long break every 4th" },
      { title: "Step away, or skip", desc: "The break never fires during a live meeting" },
      { title: "Time maps to the event", desc: "Per-event totals show up in Time Tracking" }
    ]
  },
  {
    title: "Healthy Long-Haul Day", role: "Pro", pro: true,
    desc: "You’re heads-down for eight hours. HopTab tracks time per profile so you can see the split later. Set a 30-minute daily budget on the apps that eat your day, and a quiet nudge appears the moment you pass it. Every work interval, a break overlay tells you to look away. Come Monday, a weekly digest shows exactly where the hours went.",
    steps: [
      { title: "Time tracking runs", desc: "Per-profile hours, zero effort" },
      { title: "App budget hit", desc: "Quiet nudge when you pass a daily limit" },
      { title: "Break reminder", desc: "Look-away overlay every work interval" },
      { title: "Weekly digest", desc: "A summary of last week’s time, per profile" }
    ]
  }
];

var activeWorkflow = 0;

function esc(s) {
  return String(s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function renderWorkflows() {
  var pills = document.getElementById("wf-pills");
  var detail = document.getElementById("wf-detail");
  var note = document.getElementById("wf-pro-note");
  if (!pills || !detail) return;

  pills.innerHTML = workflows.map(function (wf, i) {
    var cls = "wf-pill" + (wf.pro ? " pro" : "") + (i === activeWorkflow ? " active" : "");
    return '<button class="' + cls + '" data-i="' + i + '">' + esc(wf.title) + (wf.pro ? " *" : "") + "</button>";
  }).join("");

  var wf = workflows[activeWorkflow];
  var border = wf.pro ? ' style="border-color:#4a90d9;border-width:2px;"' : "";
  var roleStyle = wf.pro ? ' style="border-color:#4a90d9;color:#4a90d9;"' : "";
  var steps = wf.steps.map(function (step, j) {
    return '<div class="wf-step"><div class="wf-step-num">STEP ' + (j + 1) + "</div>" +
      "<strong>" + esc(step.title) + "</strong><span>" + esc(step.desc) + "</span></div>";
  }).join("");

  detail.innerHTML =
    '<div class="workflow"' + border + ">" +
      '<div class="workflow-header"><h3>' + esc(wf.title) + "</h3>" +
      '<span class="role"' + roleStyle + ">" + esc(wf.role) + "</span></div>" +
      "<p>" + esc(wf.desc) + "</p>" +
      '<div class="workflow-steps">' + steps + "</div>" +
    "</div>";

  note.innerHTML = wf.pro
    ? '* This workflow uses <a href="https://buy.polar.sh/polar_cl_iKgZQ7w4AWRhnNzsnQBl80syKnFJGHJj1Pv6d2a9tD7" style="color:#4a90d9;font-weight:600;" onclick="track(\'pro_click\',{location:\'workflow_note\'})">HopTab Pro</a> features.'
    : "";

  // Wire pill clicks
  var btns = pills.querySelectorAll(".wf-pill");
  for (var k = 0; k < btns.length; k++) {
    btns[k].addEventListener("click", function () {
      activeWorkflow = parseInt(this.getAttribute("data-i"), 10);
      track("workflow_view", { workflow: workflows[activeWorkflow].title });
      renderWorkflows();
    });
  }
}

// --- Install command copy (works for every .copy-btn on the page) -------
function wireCopyButtons() {
  var btns = document.querySelectorAll(".copy-btn");
  for (var i = 0; i < btns.length; i++) {
    (function (btn) {
      btn.addEventListener("click", function () {
        var box = btn.parentElement.querySelector(".cmd");
        if (!box) return;
        navigator.clipboard.writeText(box.textContent).then(function () {
          btn.textContent = "Copied!";
          track("install_command_copied");
          setTimeout(function () { btn.textContent = "Copy"; }, 2000);
        });
      });
    })(btns[i]);
  }
}

// --- Scroll-reveal -------------------------------------------------------
// Gentle fade/rise as sections enter view. No-JS and reduced-motion users see
// everything immediately — CSS only hides elements once .reveal-ready is set.
function wireReveal() {
  if (!("IntersectionObserver" in window)) return;
  if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  document.documentElement.classList.add("reveal-ready");
  var els = document.querySelectorAll(
    ".feature-row, .cap-card, .quote-card, #workflows .workflow, .home-cta .cta-box, .pricing-grid > div"
  );
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      if (e.isIntersecting) { e.target.classList.add("is-in"); io.unobserve(e.target); }
    });
  }, { threshold: 0.08, rootMargin: "0px 0px -40px 0px" });

  for (var i = 0; i < els.length; i++) {
    var el = els[i];
    el.classList.add("reveal");
    // Already in view at load → reveal immediately so there's no flash.
    if (el.getBoundingClientRect().top < window.innerHeight) {
      el.classList.add("is-in");
    } else {
      io.observe(el);
    }
  }
}

document.addEventListener("DOMContentLoaded", function () {
  renderWorkflows();
  wireCopyButtons();
  wireReveal();
});

// --- Install-steps sheet: shown when a download starts -------------------
// The /download link still navigates (the browser downloads the zip and stays
// on the page); this just explains the drag-and-drop install while it lands.
function wireInstallSheet() {
  var links = document.querySelectorAll('a[href="/download"]');
  if (!links.length) return;

  var sheet = null;

  function close() {
    if (!sheet) return;
    sheet.classList.remove("is-open");
    var s = sheet;
    setTimeout(function () { if (s.parentNode) s.parentNode.removeChild(s); }, 250);
    sheet = null;
    document.removeEventListener("keydown", onKey);
  }
  function onKey(e) { if (e.key === "Escape") close(); }

  function open() {
    if (sheet) return;
    sheet = document.createElement("div");
    sheet.className = "install-sheet";
    sheet.innerHTML =
      '<div class="is-scrim"></div>' +
      '<div class="is-card" role="dialog" aria-modal="true" aria-labelledby="is-title">' +
        '<button class="is-close" aria-label="Close">&times;</button>' +
        '<h3 id="is-title">Downloading HopTab&hellip;</h3>' +
        '<p class="is-sub">Three steps and you&rsquo;re tiling windows:</p>' +
        '<ol class="is-steps">' +
          '<li><b>Open the zip</b> in your Downloads folder &mdash; it unpacks to <b>HopTab.app</b>.</li>' +
          '<li><b>Drag HopTab into Applications</b> and open it. If macOS warns about an unidentified developer, right-click the app and choose <b>Open</b>.</li>' +
          '<li><b>Grant Accessibility</b> when prompted (System Settings &rarr; Privacy &amp; Security &rarr; Accessibility), then press <kbd>&#8997;</kbd>+<kbd>Tab</kbd>.</li>' +
        '</ol>' +
        '<p class="is-brew">Prefer the terminal? <code>brew tap royalbhati/tap &amp;&amp; brew install --cask hoptab</code></p>' +
      '</div>';
    document.body.appendChild(sheet);
    sheet.querySelector(".is-scrim").addEventListener("click", close);
    sheet.querySelector(".is-close").addEventListener("click", close);
    document.addEventListener("keydown", onKey);
    // Two frames so the enter transition runs from the initial state.
    requestAnimationFrame(function () { requestAnimationFrame(function () {
      sheet.classList.add("is-open");
      sheet.querySelector(".is-close").focus();
    }); });
    track("install_sheet_shown", {});
  }

  for (var i = 0; i < links.length; i++) {
    links[i].addEventListener("click", function () { open(); });
  }
}

document.addEventListener("DOMContentLoaded", wireInstallSheet);
