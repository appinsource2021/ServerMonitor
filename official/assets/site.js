// Theme switch, mobile menu and copy buttons. No dependencies, no network.
(function () {
  var root = document.documentElement;
  var KEY = 'sm-theme';

  function current() {
    return root.getAttribute('data-theme') || '';
  }

  function paint() {
    var cur = current();
    var buttons = document.querySelectorAll('[data-theme-set]');
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].setAttribute('aria-pressed', buttons[i].getAttribute('data-theme-set') === cur ? 'true' : 'false');
    }
  }

  document.addEventListener('click', function (e) {
    var b = e.target.closest('[data-theme-set]');
    if (!b) return;
    var v = b.getAttribute('data-theme-set');
    if (v) root.setAttribute('data-theme', v); else root.removeAttribute('data-theme');
    try { if (v) localStorage.setItem(KEY, v); else localStorage.removeItem(KEY); } catch (err) {}
    paint();
  });
  paint();

  var menu = document.querySelector('.menu-btn');
  var nav = document.getElementById('site-nav');
  if (menu && nav) {
    menu.addEventListener('click', function () {
      var open = nav.classList.toggle('open');
      menu.setAttribute('aria-expanded', open ? 'true' : 'false');
    });
    nav.addEventListener('click', function (e) {
      if (e.target.closest('a')) { nav.classList.remove('open'); menu.setAttribute('aria-expanded', 'false'); }
    });
  }

  var pres = document.querySelectorAll('pre');
  for (var j = 0; j < pres.length; j++) {
    (function (pre) {
      if (!navigator.clipboard) return;
      var text = pre.innerText;
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'copy-btn';
      btn.textContent = 'Copy';
      btn.addEventListener('click', function () {
        navigator.clipboard.writeText(text).then(function () {
          btn.textContent = 'Copied';
          setTimeout(function () { btn.textContent = 'Copy'; }, 1500);
        });
      });
      pre.appendChild(btn);
    })(pres[j]);
  }
})();
