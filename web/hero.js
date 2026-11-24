(() => {
  const hero = document.getElementById('hero');
  if (!hero) return;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

  function inkSplit(el, cls) {
    let n = 0;
    Array.from(el.childNodes).forEach((node) => {
      if (node.nodeType !== Node.TEXT_NODE) return;
      const frag = document.createDocumentFragment();
      Array.from(node.textContent).forEach((ch) => {
        if (!ch.trim()) { frag.appendChild(document.createTextNode(ch)); return; }
        const span = document.createElement('span');
        span.className = cls;
        span.textContent = ch;
        span.style.setProperty('--n', n++);
        frag.appendChild(span);
      });
      el.replaceChild(frag, node);
    });
    return n;
  }

  inkSplit(document.querySelector('.hero-title'), 'ink-ch');
  const poemCount = inkSplit(document.querySelector('.hero-poem'), 'ink-ch-sm');
  const poemSeal = document.querySelector('.poem-seal');
  if (poemSeal) poemSeal.style.setProperty('--n', poemCount);

  if (reduce) return;

  const map = hero.querySelector('.hero-map');
  const canvas = hero.querySelector('.hero-dust');
  const ctx = canvas.getContext('2d');
  const finePointer = matchMedia('(pointer: fine)').matches;
  const BASE_SCALE = 1.08;
  let w = 0;
  let h = 0;
  let dpr = 1;
  let mx = 0;
  let my = 0;
  let tx = 0;
  let ty = 0;
  let sy = 0;
  let visible = true;
  let raf = 0;
  let motes = [];

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    w = hero.clientWidth;
    h = hero.clientHeight;
    canvas.width = w * dpr;
    canvas.height = h * dpr;
    canvas.style.width = `${w}px`;
    canvas.style.height = `${h}px`;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    motes = Array.from({ length: Math.round(Math.min(42, w / 28)) }, () => ({
      x: Math.random() * w,
      y: Math.random() * h,
      r: 0.6 + Math.random() * 1.3,
      vy: 4 + Math.random() * 8,
      vx: (Math.random() - 0.5) * 6,
      phase: Math.random() * Math.PI * 2,
      speed: 0.4 + Math.random() * 0.8
    }));
  }

  function drawMotes(time, dt) {
    ctx.clearRect(0, 0, w, h);
    const night = document.documentElement.dataset.theme !== 'paper';
    ctx.globalCompositeOperation = night ? 'lighter' : 'source-over';
    for (const m of motes) {
      m.y -= (m.vy * dt) / h;
      m.x += (m.vx * dt) / w;
      if (m.y < -4) { m.y = h + 4; m.x = Math.random() * w; }
      if (m.x < -4) m.x = w + 4;
      if (m.x > w + 4) m.x = -4;
      const twinkle = 0.55 + 0.45 * Math.sin(time * 0.001 * m.speed + m.phase);
      const alpha = (night ? 0.55 : 0.22) * twinkle * Math.min(1, m.y / h + 0.35);
      ctx.beginPath();
      ctx.fillStyle = night
        ? `rgba(240, 200, 120, ${alpha})`
        : `rgba(168, 124, 47, ${alpha})`;
      ctx.arc(m.x, m.y, m.r, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  function frame(time) {
    raf = 0;
    mx += (tx - mx) * 0.06;
    my += (ty - my) * 0.06;
    map.style.transform = `translate3d(${mx.toFixed(2)}px, ${(my + sy).toFixed(2)}px, 0) scale(${BASE_SCALE})`;
    const now = time || performance.now();
    const dt = Math.min(64, now - (frame.last || now));
    frame.last = now;
    drawMotes(now, dt);
    if (visible) raf = requestAnimationFrame(frame);
  }

  function wake() {
    if (!raf && visible) raf = requestAnimationFrame(frame);
  }

  resize();
  window.addEventListener('resize', resize);

  if (finePointer) {
    hero.addEventListener('mousemove', (event) => {
      const rect = hero.getBoundingClientRect();
      tx = ((event.clientX - rect.left) / rect.width - 0.5) * -14;
      ty = ((event.clientY - rect.top) / rect.height - 0.5) * -8;
    });
    hero.addEventListener('mouseleave', () => { tx = 0; ty = 0; });
  }

  window.addEventListener('scroll', () => {
    sy = Math.min(window.scrollY, h) * 0.12;
    wake();
  }, { passive: true });

  new IntersectionObserver((entries) => {
    visible = entries[0].isIntersecting && !document.hidden;
    wake();
  }, { threshold: 0.05 }).observe(hero);

  document.addEventListener('visibilitychange', () => {
    visible = !document.hidden;
    wake();
  });

  wake();
})();
