/*
 * wacomd landing — shared JS
 * - Reveal-on-scroll with stagger (IntersectionObserver, vanilla).
 * - Stripe checkout wiring (ThinkSpark global Stripe Payment Link).
 *
 * Respects prefers-reduced-motion : if the user has it set, no
 * IntersectionObserver, everything is immediately visible.
 */
(function () {
  'use strict';

  // ============================================================
  // 1. STRIPE — replace this single URL with the real ThinkSpark
  //    Payment Link from your Stripe dashboard (Products → Payment
  //    Links → "wacomd config 4,99 €"). All "Buy" buttons inherit it.
  // ============================================================
  var STRIPE_PAYMENT_LINK = 'https://buy.stripe.com/REPLACE_ME_WITH_THINKSPARK_LINK';

  function wireStripe() {
    var buttons = document.querySelectorAll('[data-stripe-buy]');
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].setAttribute('href', STRIPE_PAYMENT_LINK);
      buttons[i].setAttribute('target', '_blank');
      buttons[i].setAttribute('rel', 'noopener');
    }
  }

  // ============================================================
  // 2. Reveal-on-scroll
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
      // Stagger items that come into view in the same observation cycle
      // by 60 ms — UI Pro Max guidance is 30–50 ms, we lean slightly
      // higher for elegance.
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
  // 3. Smooth scroll fix for in-page anchors when scroll-behavior
  //    isn't enough (it already is in CSS, but this handles the
  //    cross-browser focus-after-jump for accessibility).
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
        // Move focus to the section heading for screen readers.
        var h = target.querySelector('h1, h2, h3') || target;
        h.setAttribute('tabindex', '-1');
        h.focus({ preventScroll: true });
      });
    }
  }

  // ============================================================
  // boot
  // ============================================================
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      wireStripe(); reveal(); smoothAnchors();
    });
  } else {
    wireStripe(); reveal(); smoothAnchors();
  }
})();
