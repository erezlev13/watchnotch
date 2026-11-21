const film = document.querySelector("#film");
const fallback = document.querySelector("#film-error");
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

film.addEventListener("loadedmetadata", () => {
  if (!Number.isFinite(film.duration) || film.duration <= 0) {
    showFallback();
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
});

if (film.error || film.networkState === HTMLMediaElement.NETWORK_NO_SOURCE || !film.canPlayType("video/mp4")) {
  showFallback();
}
