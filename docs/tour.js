const film = document.querySelector("#film");
const chapters = Array.from(document.querySelectorAll(".chapters a"), link => ({
  link,
  start: Number(link.hash.slice(3))
}));

for (const { link, start } of chapters) {
  link.addEventListener("click", event => {
    if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey || !film.canPlayType("video/mp4")) return;
    event.preventDefault();
    film.currentTime = start;
    film.play().catch(() => film.focus());
  });
}

film.addEventListener("timeupdate", () => {
  for (let i = 0; i < chapters.length; i++) {
    const { link, start } = chapters[i];
    const end = chapters[i + 1]?.start ?? Infinity;
    if (film.currentTime >= start && film.currentTime < end) link.setAttribute("aria-current", "time");
    else link.removeAttribute("aria-current");
  }
});
