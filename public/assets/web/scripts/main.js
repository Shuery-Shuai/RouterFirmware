function copyToClipboard(sha, btnElement) {
  if (navigator.clipboard) {
    navigator.clipboard
      .writeText(sha)
      .then(() => {
        btnElement.textContent = "✅";
        btnElement.classList.add("success");
        setTimeout(() => {
          btnElement.textContent = "📋";
          btnElement.classList.remove("success");
        }, 1000);
      })
      .catch(() => showTooltip("复制失败", event));
  } else {
    prompt("请手动复制完整 SHA256：", sha);
  }
}

function showTooltip(text, e) {
  const tooltip = document.getElementById("tooltip");
  tooltip.textContent = text;
  tooltip.style.display = "block";
  tooltip.style.left = e.clientX + 10 + "px";
  tooltip.style.top = e.clientY + 10 + "px";
  setTimeout(() => (tooltip.style.display = "none"), 1000);
}
