const film = document.querySelector("#film");
const fallback = document.querySelector("#film-error");
const chapters = Array.from(document.querySelectorAll(".chapters a"), link => ({
  link,
  start: Number(link.hash.slice(3))
}));

let requestedSeek = null;
let playbackCheck = null;
let didFail = false;

function showFilmFallback() {
  if (didFail) return;
  didFail = true;
  fallback.hidden = false;
  clearTimeout(playbackCheck);
}

function seekToChapter(seconds) {
  if (film.readyState < HTMLMediaElement.HAVE_METADATA) {
    requestedSeek = seconds;
    return;
  }
  if (Number.isFinite(film.duration) && film.duration > 0) {
    try {
      film.currentTime = Math.min(seconds, Math.max(0, film.duration - 0.1));
    } catch {
      showFilmFallback();
    }
  }
}

for (const { link, start } of chapters) {
  link.addEventListener("click", event => {
    if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
    if (!film.canPlayType("video/mp4")) return;
    event.preventDefault();
    seekToChapter(start);
    film.play().catch(showFilmFallback);
  });
}

// Give mobile browsers a chance to fetch metadata before seeking.
// If the media is unreadable or playback never begins, offer a working GIF fallback.
film.addEventListener("loadedmetadata", () => {
  if (!Number.isFinite(film.duration) || film.duration <= 0) {
    showFilmFallback();
    return;
  }
  if (requestedSeek !== null) {
    seekToChapter(requestedSeek);
    requestedSeek = null;
  }
});
film.addEventListener("error", showFilmFallback);
film.querySelector("source")?.addEventListener("error", showFilmFallback);
film.addEventListener("play", () => {
  clearTimeout(playbackCheck);
  playbackCheck = setTimeout(() => {
    if (film.readyState < HTMLMediaElement.HAVE_CURRENT_DATA || film.currentTime <= 0) {
      showFilmFallback();
    }
  }, 10000);
});
film.addEventListener("playing", () => clearTimeout(playbackCheck));
film.addEventListener("timeupdate", () => {
  if (film.currentTime > 0) clearTimeout(playbackCheck);
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

if (!film.canPlayType("video/mp4")) showFilmFallback();
