const film = document.querySelector("#film");
const fallback = document.querySelector("#film-error");
const chapters = Array.from(document.querySelectorAll(".chapters a"), link => ({
  link,
  start: Number(link.hash.slice(3))
}));

let requestedSeek = null;
let playbackCheck;

function stopPlaybackCheck() {
  clearTimeout(playbackCheck);
}

function showFallback() {
  fallback.hidden = false;
  stopPlaybackCheck();
}

function checkProgress() {
  stopPlaybackCheck();
  const position = film.currentTime;
  playbackCheck = setTimeout(() => {
    if (!film.paused && film.currentTime === position) showFallback();
  }, 10000);
}

for (const { link, start } of chapters) {
  link.addEventListener("click", event => {
    if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
    if (film.error || !film.canPlayType("video/mp4")) return;
    event.preventDefault();
    film.scrollIntoView({ block: "center", behavior: "instant" });
    if (film.readyState >= HTMLMediaElement.HAVE_METADATA) {
      film.currentTime = start;
    } else {
      requestedSeek = start;
    }
    film.play().catch(error => {
      if (error.name !== "AbortError") showFallback();
    });
  });
}

film.addEventListener("loadedmetadata", () => {
  if (!Number.isFinite(film.duration) || film.duration <= 0) {
    showFallback();
  } else if (requestedSeek !== null) {
    film.currentTime = requestedSeek;
    requestedSeek = null;
  }
});
film.addEventListener("error", showFallback);
film.querySelector("source").addEventListener("error", showFallback);
film.addEventListener("play", checkProgress);
film.addEventListener("waiting", checkProgress);
film.addEventListener("pause", stopPlaybackCheck);
film.addEventListener("ended", stopPlaybackCheck);
film.addEventListener("timeupdate", () => {
  if (!film.paused && !film.seeking && film.readyState >= HTMLMediaElement.HAVE_FUTURE_DATA) {
    fallback.hidden = true;
  }
  for (let i = 0; i < chapters.length; i++) {
    const { link, start } = chapters[i];
    const end = chapters[i + 1]?.start ?? Infinity;
    if (film.currentTime >= start && film.currentTime < end) {
      link.setAttribute("aria-current", "time");
    } else {
      link.removeAttribute("aria-current");
    }
  }
});

if (film.error || film.networkState === HTMLMediaElement.NETWORK_NO_SOURCE || !film.canPlayType("video/mp4")) {
  showFallback();
}
