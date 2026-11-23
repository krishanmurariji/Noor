// Noor's website: drives the 3D parallax and finds the newest stable APK.
(() => {
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const scenes = [...document.querySelectorAll('[data-scene]')];
  const root = document.documentElement;

  // Each scene is data-length viewports tall; its stage sticks while --p
  // runs 0 → 1 across it. Layers read --p (and --depth) in CSS.
  for (const s of scenes) s.style.setProperty('--len', s.dataset.length || '1.5');
  for (const el of document.querySelectorAll('[data-depth]')) {
    el.style.setProperty('--depth', el.dataset.depth);
  }

  const ring = document.querySelector('.ring-scene');
  const ringItems = ring ? [...ring.querySelectorAll('.ring .phone')] : [];
  const ringCaption = document.querySelector('[data-ring-caption]');

  let spin = 0;
  let last = performance.now();

  function frame(now) {
    const vh = window.innerHeight;
    for (const s of scenes) {
      const r = s.getBoundingClientRect();
      const travel = Math.max(1, r.height - vh);
      const p = reduce ? 0.5 : Math.min(1, Math.max(0, -r.top / travel));
      s.style.setProperty('--p', p.toFixed(4));
      // Steps light up in turn as the scene passes (lists, call-outs).
      for (const el of s.querySelectorAll('[data-step]')) {
        const on = p >= parseFloat(el.dataset.step);
        el.style.setProperty('--on', on ? 1 : 0);
        el.toggleAttribute('data-on', on);
      }
    }
    // The carousel names the screen in front.
    if (ring && ringCaption) {
      const p = parseFloat(ring.style.getPropertyValue('--p')) || 0;
      const n = ringItems.length;
      const front = ((Math.round(p * 300 / (360 / n)) % n) + n) % n;
      const text = ringItems[front].querySelector('figcaption').textContent;
      if (ringCaption.textContent !== text) ringCaption.textContent = text;
    }

    // The records keep turning, faster while you scroll.
    const dt = Math.min(64, now - last);
    last = now;
    spin = (spin + dt * 0.012 * (1 + scrollSpeed * 6)) % 360;
    scrollSpeed *= 0.92;
    root.style.setProperty('--spin', reduce ? 0 : spin.toFixed(2));
    requestAnimationFrame(frame);
  }

  let scrollSpeed = 0;
  let lastY = window.scrollY;
  window.addEventListener('scroll', () => {
    scrollSpeed = Math.min(3, scrollSpeed + Math.abs(window.scrollY - lastY) / 400);
    lastY = window.scrollY;
  }, { passive: true });
  requestAnimationFrame(frame);

  // The record player tilts toward the pointer (on devices with a mouse).
  const tilt = document.querySelector('[data-tilt]');
  if (tilt && !reduce && window.matchMedia('(pointer: fine)').matches) {
    window.addEventListener('pointermove', (e) => {
      const x = e.clientX / window.innerWidth - 0.5;
      const y = e.clientY / window.innerHeight - 0.5;
      tilt.style.translate = `${x * 18}px ${y * 12}px`;
      tilt.style.rotate = `${-y * 4}deg ${x * 6}deg 0 1deg`;
    }, { passive: true });
  }

  // Download: the newest stable build (from master), as the app itself
  // updates. Falls back to the releases page.
  const RELEASES = 'https://api.github.com/repos/krishanmurariji/Noor/releases?per_page=30';
  fetch(RELEASES, { headers: { Accept: 'application/vnd.github+json' } })
    .then((r) => (r.ok ? r.json() : []))
    .then((list) => {
      const stable = (Array.isArray(list) ? list : []).find((r) =>
        !r.draft && !r.prerelease &&
        /Channel: stable|from `master`/.test(r.body || '') &&
        /Signed with the Noor release key/.test(r.body || ''));
      const apk = stable && (stable.assets || []).find((a) => a.name === 'noor.apk');
      if (!apk) return;
      for (const a of document.querySelectorAll('[data-download]')) a.href = apk.browser_download_url;
      const mb = (apk.size / 1048576).toFixed(0);
      const n = (stable.tag_name || '').replace('build-', '');
      for (const el of document.querySelectorAll('[data-label]')) el.textContent = `Download the APK · ${mb} MB`;
      for (const el of document.querySelectorAll('[data-build]')) {
        el.textContent = `Build ${n}, signed. It keeps itself up to date.`;
      }
    })
    .catch(() => {});
})();
