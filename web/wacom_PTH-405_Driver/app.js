/*
 * wacomd landing — shared JS
 * - Reveal-on-scroll with stagger (IntersectionObserver, vanilla).
 * - Tip-jar links are plain anchors ; user-set URLs live in the HTML.
 *
 * Respects prefers-reduced-motion : if the user has it set, no
 * IntersectionObserver, everything is immediately visible.
 */
(function () {
  'use strict';

  // ============================================================
  // Reveal-on-scroll
  // ============================================================
  function reveal() {
    var els = document.querySelectorAll('.reveal');
    if (!els.length) return;

    var prefersReduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (prefersReduce || !('IntersectionObserver' in window)) {
      for (var i = 0; i < els.length; i++) els[i].classList.add('is-visible');
      return;
    }

    var observer = new IntersectionObserver(function (entries) {
      var visibleInBatch = 0;
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i];
        if (!entry.isIntersecting) continue;
        var delay = visibleInBatch * 60;
        entry.target.style.setProperty('--reveal-delay', delay + 'ms');
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
        visibleInBatch++;
      }
    }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });

    for (var j = 0; j < els.length; j++) observer.observe(els[j]);
  }

  // ============================================================
  // Smooth scroll fix for in-page anchors + focus move for a11y
  // ============================================================
  function smoothAnchors() {
    var anchors = document.querySelectorAll('a[href^="#"]:not([href="#"])');
    for (var i = 0; i < anchors.length; i++) {
      anchors[i].addEventListener('click', function (e) {
        var id = this.getAttribute('href').slice(1);
        var target = document.getElementById(id);
        if (!target) return;
        e.preventDefault();
        target.scrollIntoView({ behavior: 'smooth', block: 'start' });
        var h = target.querySelector('h1, h2, h3') || target;
        h.setAttribute('tabindex', '-1');
        h.focus({ preventScroll: true });
      });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { reveal(); smoothAnchors(); });
  } else {
    reveal(); smoothAnchors();
  }
})();
