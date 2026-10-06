// Adds a "Copy" button to every Pygments-highlighted code block
// (`<div class="highlight"><pre>...</pre></div>`, emitted by Markdown's
// codehilite extension — see website/README.md). No dependencies, no
// build step, same philosophy as the rest of this theme.
(function () {
  function copyText(text, button) {
    function done(ok) {
      button.textContent = ok ? "Copied" : "Failed";
      button.dataset.copied = ok ? "true" : "false";
      setTimeout(function () {
        button.textContent = "Copy";
        delete button.dataset.copied;
      }, 1500);
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(
        function () { done(true); },
        function () { done(false); }
      );
    } else {
      var area = document.createElement("textarea");
      area.value = text;
      area.style.position = "fixed";
      area.style.opacity = "0";
      document.body.appendChild(area);
      area.select();
      var ok = false;
      try {
        ok = document.execCommand("copy");
      } catch (e) {
        ok = false;
      }
      document.body.removeChild(area);
      done(ok);
    }
  }

  document.querySelectorAll("div.highlight").forEach(function (block) {
    var pre = block.querySelector("pre");
    if (!pre) return;
    var button = document.createElement("button");
    button.type = "button";
    button.className = "copy-code";
    button.textContent = "Copy";
    button.setAttribute("aria-label", "Copy code to clipboard");
    button.addEventListener("click", function () {
      copyText(pre.textContent, button);
    });
    block.appendChild(button);
  });
})();
