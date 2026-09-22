(function (label) {
  function walk(n) {
    if (n.nodeType === 3) { return "#" + n.nodeValue; }
    if (n.nodeType === 8) { return "!" + n.nodeValue; }
    var out = n.nodeName + "@" + n.namespaceURI + "[";
    for (var i = 0; i < n.attributes.length; i++) {
      out += n.attributes[i].name + "=" + n.attributes[i].value + ";";
    }
    return out + "](" + kids(n) + ")";
  }
  function kids(n) {
    var out = "";
    for (var c = n.firstChild; c; c = c.nextSibling) { out += walk(c) + ","; }
    return out;
  }
  function press(text) {
    var all = document.querySelectorAll("button");
    for (var i = 0; i < all.length; i++) {
      if (all[i].textContent === text) { all[i].click(); return; }
    }
  }
  function first(a, b) {
    var i = 0;
    while (i < a.length && a[i] === b[i]) { i++; }
    return a.slice(Math.max(0, i - 40), i + 60) + " / " + b.slice(Math.max(0, i - 40), i + 60);
  }
  var began = Date.now();
  return new Promise(function (done) {
    var target = -1;
    (function wait() {
      if (Date.now() - began > 5000) { done("no answer from the window"); return; }
      if (target < 0) {
        if (sock.readyState !== 1 || !root.firstChild) { setTimeout(wait, 10); return; }
        if (window.hiveAcks === undefined) {
          window.hiveAcks = 0;
          var was = sock.onmessage;
          sock.onmessage = function (e) {
            was.call(this, e);
            if (e.data === "A") { window.hiveAcks++; }
          };
        }
        target = window.hiveAcks + 2;
        press(label);
        press("same");
      }
      if (window.hiveAcks < target) { setTimeout(wait, 10); return; }
      var fresh = new WebSocket(sock.url);
      fresh.onmessage = function (e) {
        if (e.data.charAt(0) !== "H") { return; }
        fresh.close();
        var draft = document.createElement("div");
        draft.innerHTML = e.data.slice(1);
        var live = kids(root), want = kids(draft);
        done(live === want ? "same page" : "differs: " + first(live, want));
      };
    })();
  });
})
