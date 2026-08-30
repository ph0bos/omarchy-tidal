"""HTTP endpoints for the things Mopidy's core API has no concept of.

Mopidy gives us search, browse, and playback for free over JSON-RPC. It has no
notion of lyrics, Tidal's personalised home, radio seeds, favourites, or the
sample rate a stream actually negotiated -- so those live here, in-process with
mopidy-tidal so the authenticated session can be shared.

Two things worth knowing about the implementation:

* Every tidalapi call is blocking and some take seconds. Tornado runs Mopidy's
  whole HTTP server on one IOLoop, so a blocking call here would stall the
  JSON-RPC endpoint the rest of the plugin depends on. All of them are pushed
  onto an executor.
* Mopidy binds to 127.0.0.1, but "localhost" is reachable from any page in the
  user's browser. Requests carrying a cross-origin `Origin` header are rejected
  so a web page cannot read someone's library or drive their playback.
"""

from __future__ import annotations

import json
import logging
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlparse

import tornado.httpclient
import tornado.ioloop
import tornado.web

from . import images as images_mod
from . import lyrics as lyrics_mod
from . import palette as palette_mod
from . import text as text_mod
from .session import SessionProvider, entity_id, track_id

logger = logging.getLogger(__name__)

# tidalapi is blocking and occasionally slow; keep it off the IOLoop.
_EXECUTOR = ThreadPoolExecutor(max_workers=4, thread_name_prefix="omarchy-tidal")

# Cache negotiated stream formats. get_stream() is a real API round trip and the
# answer cannot change for a given track.
_FORMAT_CACHE: dict[str, dict] = {}
_FORMAT_CACHE_MAX = 256

# Art is looked up one entity at a time and a scrolling list asks for many at
# once, so cover art gets its own workers rather than queueing behind lyrics
# and stream formats on the shared pool.
_ART_EXECUTOR = ThreadPoolExecutor(max_workers=8, thread_name_prefix="omarchy-tidal-art")

# Only Tidal's own asset host is fetchable through /art. Without this the
# endpoint is an open proxy that anything on the machine could point at a
# private address.
_ART_HOSTS = ("resources.tidal.com",)

# Pruning walks the whole cache directory, so it runs on a write every so often
# rather than on every one.
_ART_WRITES_PER_PRUNE = 100
_art_writes = 0


class BaseHandler(tornado.web.RequestHandler):
    def initialize(self, provider: SessionProvider, core, config) -> None:
        self.provider = provider
        self.core = core
        self.ext_config = config.get("omarchy_tidal") or {}

    def prepare(self) -> None:
        # A browser always sets Origin on cross-origin requests; the QML client
        # sets none. Anything with an Origin is not our client.
        if self.request.headers.get("Origin"):
            raise tornado.web.HTTPError(403, "cross-origin requests are not allowed")

    def write_json(self, payload) -> None:
        self.set_header("Content-Type", "application/json")
        self.write(json.dumps(payload))

    def session_or_503(self):
        session = self.provider.get()
        if session is None:
            self.set_status(503)
            self.write_json({"error": "not signed in to Tidal"})
            return None
        return session

    async def run(self, fn, *args):
        return await tornado.ioloop.IOLoop.current().run_in_executor(_EXECUTOR, fn, *args)

    async def describe(self, session, uri: str, size: int = 320):
        """What a Tidal URI is, cached. /art and /entity ask the same question."""
        key = f"{uri}@{size}"
        hit, payload = images_mod.cached(key)
        if hit:
            return payload
        payload = await tornado.ioloop.IOLoop.current().run_in_executor(
            _ART_EXECUTOR, images_mod.describe, session, uri, size)
        images_mod.remember(key, payload)
        return payload

    def body_json(self) -> dict:
        if not self.request.body:
            return {}
        try:
            return json.loads(self.request.body.decode("utf-8")) or {}
        except (ValueError, UnicodeDecodeError):
            return {}


class HealthHandler(BaseHandler):
    async def get(self) -> None:
        logged_in = await self.run(self.provider.logged_in)
        self.write_json({
            "ok": True,
            "logged_in": logged_in,
            "quality": str(self.provider.quality),
        })


class AuthStatusHandler(BaseHandler):
    async def get(self) -> None:
        logged_in = await self.run(self.provider.logged_in)
        payload = {"logged_in": logged_in, "quality": str(self.provider.quality)}
        if logged_in:
            session = self.provider.get()
            user = getattr(session, "user", None)
            payload["user_id"] = getattr(user, "id", None)
        self.write_json(payload)


class LyricsHandler(BaseHandler):
    async def get(self) -> None:
        uri = self.get_argument("uri", "")
        tid = track_id(uri)
        if tid is None:
            self.set_status(400)
            self.write_json({"error": "expected a tidal:track: uri"})
            return

        session = self.session_or_503()
        if session is None:
            return

        allow_lrclib = bool(self.ext_config.get("lrclib_fallback", True))

        def work():
            track = session.track(int(tid))
            return lyrics_mod.resolve(track, allow_lrclib=allow_lrclib)

        try:
            result = await self.run(work)
        except Exception:
            logger.exception("Lyrics lookup failed for %s", uri)
            result = {"synced": [], "plain": "", "source": None}

        result["uri"] = uri
        self.write_json(result)


def image_of(obj, size=320):
    try:
        return obj.image(size)
    except Exception:
        return None


def _item_payload(item) -> dict | None:
    """Flatten a tidalapi album/track/playlist/mix into something the UI can use."""
    kind = type(item).__name__.lower()

    def image(size=320):
        return image_of(item, size)

    try:
        if kind == "track":
            return {
                "type": "track",
                "uri": f"tidal:track:{item.id}",
                "name": item.name,
                "artist": item.artist.name if item.artist else "",
                "album": item.album.name if item.album else "",
                "duration": getattr(item, "duration", None),
                "track_num": getattr(item, "track_num", None),
                # Tracks carry no art of their own; the album's is what renders.
                "image": image_of(item.album) if item.album else None,
                "hires": bool(getattr(item, "is_hi_res_lossless", False)),
            }
        if kind == "album":
            return {
                "type": "album",
                "uri": f"tidal:album:{item.id}",
                "name": item.name,
                "artist": item.artist.name if item.artist else "",
                "year": images_mod.year_of(item),
                "image": image(),
                "hires": "HIRES_LOSSLESS" in (getattr(item, "media_metadata_tags", None) or []),
            }
        if kind == "artist":
            return {
                "type": "artist",
                "uri": f"tidal:artist:{item.id}",
                "name": item.name,
                "artist": "",
                "image": image(),
            }
        if kind in ("playlist", "userplaylist"):
            return {
                "type": "playlist",
                "uri": f"tidal:playlist:{item.id}",
                "name": item.name,
                "artist": (getattr(item, "creator", None)
                           and getattr(item.creator, "name", "")) or "",
                "image": image(),
            }
        if kind == "mix":
            return {
                "type": "mix",
                "uri": f"tidal:mix:{item.id}",
                "name": getattr(item, "title", "") or getattr(item, "name", ""),
                "artist": getattr(item, "sub_title", "") or "",
                "image": None,
            }
    except Exception:
        return None
    return None


class HomeHandler(BaseHandler):
    """Tidal's personalised front page, flattened into titled rows."""

    async def get(self) -> None:
        session = self.session_or_503()
        if session is None:
            return

        def work():
            rows = []
            for page_name in ("home", "for_you"):
                getter = getattr(session, page_name, None)
                if getter is None:
                    continue
                try:
                    page = getter()
                except Exception:
                    continue
                for category in getattr(page, "categories", []) or []:
                    title = getattr(category, "title", "") or ""
                    items = []
                    for item in (getattr(category, "items", None) or [])[:20]:
                        payload = _item_payload(item)
                        if payload:
                            items.append(payload)
                    if items:
                        rows.append({"title": title, "items": items})
            return rows

        try:
            rows = await self.run(work)
        except Exception:
            logger.exception("Tidal home lookup failed")
            rows = []

        self.write_json({"rows": rows})


class FavoriteHandler(BaseHandler):
    async def get(self) -> None:
        uri = self.get_argument("uri", "")
        tid = track_id(uri)
        if tid is None:
            self.set_status(400)
            self.write_json({"error": "expected a tidal:track: uri"})
            return

        session = self.session_or_503()
        if session is None:
            return

        def work():
            wanted = int(tid)
            # tracks() is paginated; favorites can be large, so stop early.
            for track in session.user.favorites.tracks(limit=1000):
                if int(track.id) == wanted:
                    return True
            return False

        try:
            is_fav = await self.run(work)
        except Exception:
            logger.exception("Favorite lookup failed for %s", uri)
            is_fav = False

        self.write_json({"uri": uri, "favorite": is_fav})

    async def post(self) -> None:
        body = self.body_json()
        uri = str(body.get("uri") or "")
        want = bool(body.get("favorite", True))
        tid = track_id(uri)
        if tid is None:
            self.set_status(400)
            self.write_json({"error": "expected a tidal:track: uri"})
            return

        session = self.session_or_503()
        if session is None:
            return

        def work():
            favorites = session.user.favorites
            if want:
                favorites.add_track(int(tid))
            else:
                favorites.remove_track(int(tid))
            return True

        try:
            await self.run(work)
        except Exception:
            logger.exception("Favorite update failed for %s", uri)
            self.set_status(502)
            self.write_json({"error": "could not update favorites"})
            return

        self.write_json({"uri": uri, "favorite": want})


class RadioHandler(BaseHandler):
    """An infinite-ish queue seeded from a track or artist."""

    async def get(self) -> None:
        uri = self.get_argument("uri", "")
        session = self.session_or_503()
        if session is None:
            return

        tid = track_id(uri)
        aid = entity_id(uri, "artist")
        if tid is None and aid is None:
            self.set_status(400)
            self.write_json({"error": "expected a tidal:track: or tidal:artist: uri"})
            return

        def work():
            if tid is not None:
                tracks = session.track(int(tid)).get_track_radio()
            else:
                tracks = session.artist(int(aid)).get_radio()
            return [f"tidal:track:{t.id}" for t in (tracks or [])]

        try:
            uris = await self.run(work)
        except Exception:
            logger.exception("Radio lookup failed for %s", uri)
            uris = []

        self.write_json({"seed": uri, "uris": uris})


class SimilarHandler(BaseHandler):
    async def get(self) -> None:
        uri = self.get_argument("uri", "")
        session = self.session_or_503()
        if session is None:
            return

        aid = entity_id(uri, "artist")
        alid = entity_id(uri, "album")
        if aid is None and alid is None:
            self.set_status(400)
            self.write_json({"error": "expected a tidal:artist: or tidal:album: uri"})
            return

        def work():
            if aid is not None:
                items = session.artist(int(aid)).get_similar()
            else:
                items = session.album(int(alid)).similar()
            out = []
            for item in (items or [])[:20]:
                payload = _item_payload(item)
                if payload:
                    out.append(payload)
            return out

        try:
            items = await self.run(work)
        except Exception:
            logger.exception("Similar lookup failed for %s", uri)
            items = []

        self.write_json({"uri": uri, "items": items})


def _safe(fn, default=None):
    """tidalapi raises for absent optional metadata; treat that as "not there"."""
    try:
        return fn()
    except Exception:
        return default


class ArtistHandler(BaseHandler):
    """Everything an artist page needs in one round trip.

    The UI would otherwise make five calls (bio, image, top tracks, albums,
    similar) and render progressively, which looks broken on a slow link.
    """

    async def get(self) -> None:
        uri = self.get_argument("uri", "")
        aid = entity_id(uri, "artist")
        if aid is None:
            self.set_status(400)
            self.write_json({"error": "expected a tidal:artist: uri"})
            return

        session = self.session_or_503()
        if session is None:
            return

        def work():
            artist = session.artist(int(aid))
            bio_text, bio_links = text_mod.clean(_safe(artist.get_bio))
            top = _safe(lambda: artist.get_top_tracks(limit=10), []) or []
            albums = _safe(lambda: artist.get_albums(limit=12), []) or []
            similar = _safe(artist.get_similar, []) or []
            return {
                "uri": f"tidal:artist:{artist.id}",
                "name": artist.name,
                "image": _safe(lambda: artist.image(750)) or _safe(lambda: artist.image(320)),
                "bio": bio_text,
                "bio_links": bio_links,
                "roles": [str(r) for r in (getattr(artist, "roles", None) or [])],
                "share_url": _safe(lambda: artist.share_url),
                "top_tracks": [p for p in (_item_payload(t) for t in top) if p],
                "albums": [p for p in (_item_payload(a) for a in albums) if p],
                "similar": [p for p in (_item_payload(a) for a in similar[:12]) if p],
            }

        try:
            payload = await self.run(work)
        except Exception:
            logger.exception("Artist lookup failed for %s", uri)
            self.set_status(502)
            self.write_json({"error": "could not load the artist"})
            return

        self.write_json(payload)


class AlbumHandler(BaseHandler):
    """Album detail: art, credits, review, and the track list."""

    async def get(self) -> None:
        uri = self.get_argument("uri", "")
        alid = entity_id(uri, "album")
        if alid is None:
            self.set_status(400)
            self.write_json({"error": "expected a tidal:album: uri"})
            return

        session = self.session_or_503()
        if session is None:
            return

        def work():
            album = session.album(int(alid))
            review_text, review_links = text_mod.clean(_safe(album.review))
            tracks = _safe(album.tracks, []) or []
            release = _safe(lambda: album.release_date)
            tags = getattr(album, "media_metadata_tags", None) or []
            return {
                "uri": f"tidal:album:{album.id}",
                "name": album.name,
                "artist": album.artist.name if album.artist else "",
                "artist_uri": f"tidal:artist:{album.artist.id}" if album.artist else "",
                "image": _safe(lambda: album.image(640)) or _safe(lambda: album.image(320)),
                "year": getattr(album, "year", None),
                "release_date": str(release) if release else None,
                "num_tracks": getattr(album, "num_tracks", None),
                "duration": getattr(album, "duration", None),
                "copyright": (getattr(album, "copyright", None) or "").strip(),
                "review": review_text,
                "review_links": review_links,
                "hires": "HIRES_LOSSLESS" in tags,
                "share_url": _safe(lambda: album.share_url),
                "tracks": [p for p in (_item_payload(t) for t in tracks) if p],
            }

        try:
            payload = await self.run(work)
        except Exception:
            logger.exception("Album lookup failed for %s", uri)
            self.set_status(502)
            self.write_json({"error": "could not load the album"})
            return

        self.write_json(payload)


class FormatHandler(BaseHandler):
    """The stream format Tidal actually served for what is playing.

    This reports the source, which is the honest answer to "am I getting
    hi-res". It is deliberately not the rate the sound card ended up running at
    -- PipeWire may resample downstream, and an output device can refuse a rate
    outright (many displays reject 88.2 kHz over HDMI).
    """

    async def get(self) -> None:
        session = self.session_or_503()
        if session is None:
            return

        def current_uri():
            track = self.core.playback.get_current_track().get()
            return track.uri if track else None

        uri = await self.run(current_uri)
        tid = track_id(uri or "")
        if tid is None:
            self.write_json({"uri": uri, "codec": None, "bit_depth": None,
                             "sample_rate": None, "quality": None, "is_hires": False})
            return

        cached = _FORMAT_CACHE.get(tid)
        if cached is not None:
            self.write_json(dict(cached, uri=uri))
            return

        def work():
            track = session.track(int(tid))
            stream = track.get_stream()
            bit_depth, sample_rate = stream.get_audio_resolution()
            quality = str(stream.audio_quality)
            return {
                # Tidal serves FLAC for both lossless tiers and AAC below them.
                "codec": "FLAC" if "LOSSLESS" in quality.upper() else "AAC",
                "bit_depth": bit_depth,
                "sample_rate": sample_rate,
                "quality": quality,
                "is_hires": bool(getattr(track, "is_hi_res_lossless", False)),
            }

        try:
            payload = await self.run(work)
        except Exception:
            logger.exception("Stream format lookup failed for %s", uri)
            payload = {"codec": None, "bit_depth": None, "sample_rate": None,
                       "quality": None, "is_hires": False}
        else:
            if len(_FORMAT_CACHE) >= _FORMAT_CACHE_MAX:
                _FORMAT_CACHE.clear()
            _FORMAT_CACHE[tid] = payload

        self.write_json(dict(payload, uri=uri))


def _content_type(payload: bytes) -> str:
    """Sniffed, not trusted: Tidal serves jpeg today and the URL says nothing."""
    if payload.startswith(b"\x89PNG"):
        return "image/png"
    if payload[:4] == b"RIFF" and payload[8:12] == b"WEBP":
        return "image/webp"
    return "image/jpeg"


async def _artwork_bytes(handler, uri: str, url: str, size: int):
    """The bytes of a piece of artwork, from disk if they are already here.

    Shared by /art, which serves them, and /palette, which measures them: both
    want the same file and neither should fetch it twice.
    """
    key = url or f"{uri}@{size}"
    root = images_mod.cache_dir()
    path = images_mod.path_for(key, root)

    if path.is_file():
        payload = await handler.run(path.read_bytes)
        images_mod.touch(path)
        return payload, url

    if not url:
        session = handler.session_or_503()
        if session is None:
            return None, ""
        described = await handler.describe(session, uri, size)
        url = (described or {}).get("image") or ""
        if not url:
            return None, ""
        path = images_mod.path_for(url or key, root)
        if path.is_file():
            payload = await handler.run(path.read_bytes)
            images_mod.touch(path)
            return payload, url

    host = (urlparse(url).hostname or "").lower()
    if host not in _ART_HOSTS:
        return None, url

    try:
        response = await tornado.httpclient.AsyncHTTPClient().fetch(
            url, connect_timeout=5, request_timeout=15)
    except Exception as exc:
        logger.debug("omarchy-tidal: could not fetch art %s: %s", url, exc)
        return None, url

    await handler.run(images_mod.write_atomic, path, response.body)
    return response.body, url


class PaletteHandler(BaseHandler):
    """How light a sleeve is, and what colour it is.

    The interface draws text over a blurred cover and a spectrum analyser
    beside it. Both need to know what the cover looks like: a white sleeve
    makes muted metadata unreadable, and an analyser in the theme's accent
    ignores the record entirely.
    """

    async def get(self) -> None:
        uri = self.get_argument("uri", "")
        url = self.get_argument("url", "")
        if not uri and not url:
            self.set_status(400)
            self.write_json({"error": "expected a uri or a url"})
            return

        cache_key = "palette:" + (url or uri)
        hit, cached = images_mod.cached(cache_key)
        if hit:
            self.write_json(cached or {"luma": 0.0, "color": None, "isLight": False})
            return

        payload, _resolved = await _artwork_bytes(self, uri, url, 320)
        if payload is None:
            self.set_status(404)
            self.write_json({"error": "no artwork to measure"})
            return

        # Decoding happens off the loop: it is a 16x16 scale of a jpeg, but it
        # is still a decode.
        result = await tornado.ioloop.IOLoop.current().run_in_executor(
            _ART_EXECUTOR, palette_mod.analyse, payload)
        if result is None:
            self.set_status(415)
            self.write_json({"error": "could not read that artwork"})
            return

        images_mod.remember(cache_key, result)
        self.write_json(result)


class ArtHandler(BaseHandler):
    """Cover art for a URI, cached on disk.

    Every list in the UI shows artwork, which is a lot of images for a library
    of any size. Pointing the UI straight at resources.tidal.com would re-fetch
    the same sleeves on every scroll and again after every shell restart, since
    Qt's pixmap cache lives and dies with the process. Fetching through here
    means each image crosses the network once, ever.

    Takes either a `uri` to resolve (a browse ref has no art of its own) or a
    `url` already in hand from /home or /album, so both paths share the cache.
    """

    async def get(self) -> None:
        uri = self.get_argument("uri", "")
        url = self.get_argument("url", "")
        try:
            size = max(80, min(1280, int(self.get_argument("size", "320"))))
        except ValueError:
            size = 320

        if not uri and not url:
            self.set_status(400)
            self.write_json({"error": "expected a uri or a url"})
            return

        key = url or f"{uri}@{size}"
        root = images_mod.cache_dir()
        path = images_mod.path_for(key, root)

        if path.is_file():
            payload = await self.run(path.read_bytes)
            images_mod.touch(path)
            self.serve(payload)
            return

        if not url:
            session = self.session_or_503()
            if session is None:
                return
            described = await self.describe(session, uri, size)
            url = (described or {}).get("image") or ""
            if not url:
                # No art exists for this entity. 404 rather than a placeholder:
                # the UI already knows what to draw in its place.
                self.set_status(404)
                self.finish()
                return

        host = (urlparse(url).hostname or "").lower()
        if host not in _ART_HOSTS:
            self.set_status(400)
            self.write_json({"error": "refusing to fetch art from " + (host or "nowhere")})
            return

        try:
            response = await tornado.httpclient.AsyncHTTPClient().fetch(
                url, connect_timeout=5, request_timeout=15)
        except Exception as exc:
            logger.debug("omarchy-tidal: could not fetch art %s: %s", url, exc)
            self.set_status(502)
            self.finish()
            return

        payload = response.body
        await self.run(images_mod.write_atomic, path, payload)
        self.maybe_prune(root)
        self.serve(payload)

    def serve(self, payload: bytes) -> None:
        self.set_header("Content-Type", _content_type(payload))
        # Art is immutable: the URL contains the cover id, so a change of
        # sleeve is a change of URL.
        self.set_header("Cache-Control", "public, max-age=31536000, immutable")
        self.write(payload)

    def maybe_prune(self, root) -> None:
        global _art_writes
        _art_writes += 1
        if _art_writes % _ART_WRITES_PER_PRUNE:
            return
        tornado.ioloop.IOLoop.current().run_in_executor(
            _ART_EXECUTOR, images_mod.prune, root, images_mod.DEFAULT_MAX_BYTES)


# What `browse()` calls a directory and what Tidal calls a favourites list.
_LIBRARY_SECTIONS = {
    "albums": "albums",
    "artists": "artists",
    "tracks": "tracks",
    "playlists": "playlists",
    # The uris the sidebar browses, so the UI can hand over whichever it has.
    "tidal:my_albums": "albums",
    "tidal:my_artists": "artists",
    "tidal:my_tracks": "tracks",
    "tidal:my_playlists": "playlists",
}


class LibraryHandler(BaseHandler):
    """A page of someone's favourites, with the metadata attached.

    `browse(tidal:my_albums)` returns twelve hundred bare refs -- a name and a
    type each -- and the UI then has to ask what every one of them is. Tidal
    hands back the same list as objects, so one request here replaces a request
    per row, and the rows arrive complete.

    Paged rather than exhaustive: a library of a thousand albums is twenty
    round trips to Tidal, and nobody scrolls that far before the first screen
    has to be on screen.
    """

    async def get(self) -> None:
        section = _LIBRARY_SECTIONS.get(self.get_argument("section", ""))
        if section is None:
            self.set_status(400)
            self.write_json({"error": "unknown section"})
            return

        try:
            limit = max(1, min(200, int(self.get_argument("limit", "100"))))
            offset = max(0, int(self.get_argument("offset", "0")))
        except ValueError:
            limit, offset = 100, 0

        session = self.session_or_503()
        if session is None:
            return

        def work():
            favorites = session.user.favorites
            return list(getattr(favorites, section)(limit=limit, offset=offset) or [])

        try:
            found = await self.run(work)
        except Exception as exc:
            logger.warning("omarchy-tidal: %s favourites failed: %s", section, exc)
            self.set_status(502)
            self.write_json({"error": str(exc)})
            return

        items = [payload for payload in (_item_payload(item) for item in found) if payload]
        self.write_json({
            "section": section,
            "offset": offset,
            "limit": limit,
            "items": items,
            # Tidal does not report a total, so "there may be more" is the
            # honest answer: a short page is the end of the list.
            "more": len(found) >= limit,
        })


def _track_ids(uris) -> list[str]:
    """Tidal wants ids, not uris, and both of mopidy-tidal's shapes end in one."""
    out = []
    for uri in uris or []:
        parsed = images_mod.split(str(uri))
        if parsed and parsed[0] == "track":
            out.append(parsed[1])
    return out


class PlaylistsHandler(BaseHandler):
    """The playlists this account can write to.

    `session.user.playlists()` is the editable set -- what someone made
    themselves -- as opposed to the favourites list, which includes other
    people's and cannot be added to.
    """

    async def get(self) -> None:
        session = self.session_or_503()
        if session is None:
            return

        def work():
            return list(session.user.playlists() or [])

        try:
            found = await self.run(work)
        except Exception as exc:
            logger.warning("omarchy-tidal: could not list playlists: %s", exc)
            self.set_status(502)
            self.write_json({"error": str(exc)})
            return

        items = []
        for playlist in found:
            payload = _item_payload(playlist)
            if payload:
                payload["num_tracks"] = getattr(playlist, "num_tracks", None)
                items.append(payload)
        self.write_json({"items": items})


class PlaylistEditHandler(BaseHandler):
    """A playlist page, and the edits you can make to one.

    GET is the page the UI draws; POST is add, remove and create.

    Add to, remove from, and create playlists.

    One handler for the three because they share the argument checking and the
    "which playlist" lookup, and because they are the same request to the UI:
    something happened to a playlist.
    """

    async def get(self) -> None:
        uri = self.get_argument("uri", "")
        parsed = images_mod.split(uri)
        if parsed is None or parsed[0] != "playlist":
            self.set_status(400)
            self.write_json({"error": "expected a tidal:playlist: uri"})
            return

        session = self.session_or_503()
        if session is None:
            return

        def work():
            playlist = session.playlist(parsed[1])
            creator = getattr(playlist, "creator", None)
            tracks = []
            for item in _safe(lambda: playlist.tracks(limit=100), []) or []:
                payload = _item_payload(item)
                if payload:
                    tracks.append(payload)
            return {
                "uri": uri,
                "type": "playlist",
                "name": getattr(playlist, "name", "") or "",
                "creator": str(getattr(creator, "name", "") or "") if creator else "",
                # Only your own playlists can be edited. Tidal reports the
                # creator's id, so this is a comparison rather than a guess at
                # what "me" means.
                "editable": creator is not None
                and str(getattr(creator, "id", "")) == str(getattr(session.user, "id", "")),
                "description": text_mod.clean(getattr(playlist, "description", "") or "")[0],
                "image": image_of(playlist, 640) or image_of(playlist, 320),
                "num_tracks": getattr(playlist, "num_tracks", None),
                "duration": getattr(playlist, "duration", None),
                "last_updated": str(getattr(playlist, "last_updated", "") or ""),
                "tracks": tracks,
                "share_url": f"https://tidal.com/browse/playlist/{parsed[1]}",
            }

        try:
            self.write_json(await self.run(work))
        except Exception as exc:
            logger.warning("omarchy-tidal: playlist page failed: %s", exc)
            self.set_status(502)
            self.write_json({"error": str(exc)})

    async def post(self) -> None:
        body = self.body_json()
        action = str(body.get("action") or "add")
        session = self.session_or_503()
        if session is None:
            return

        if action == "create":
            name = str(body.get("name") or "").strip()
            if not name:
                self.set_status(400)
                self.write_json({"error": "a playlist needs a name"})
                return

            def make():
                created = session.user.create_playlist(name, str(body.get("description") or ""))
                return {"uri": f"tidal:playlist:{created.id}", "name": created.name}

            try:
                self.write_json(await self.run(make))
            except Exception as exc:
                logger.warning("omarchy-tidal: could not create playlist: %s", exc)
                self.set_status(502)
                self.write_json({"error": str(exc)})
            return

        parsed = images_mod.split(str(body.get("playlist") or ""))
        if parsed is None or parsed[0] != "playlist":
            self.set_status(400)
            self.write_json({"error": "expected a tidal:playlist: uri"})
            return
        playlist_id = parsed[1]

        ids = _track_ids(body.get("uris"))
        if not ids:
            self.set_status(400)
            self.write_json({"error": "expected one or more tidal:track: uris"})
            return

        def edit():
            import tidalapi

            playlist = tidalapi.playlist.UserPlaylist(session, playlist_id)
            if action == "remove":
                for media_id in ids:
                    playlist.remove_by_id(media_id)
                return {"removed": len(ids)}
            playlist.add(ids)
            return {"added": len(ids)}

        try:
            self.write_json(await self.run(edit))
        except Exception as exc:
            logger.warning("omarchy-tidal: playlist %s failed: %s", action, exc)
            self.set_status(502)
            self.write_json({"error": str(exc)})


class EntityHandler(BaseHandler):
    """What a URI is: name, artist, year, art.

    `browse()` answers with a name and a type and nothing else, so a row for an
    album in someone's library had no artist to show under it. Rows ask here
    for the rest, and because the answer is the same object the artwork came
    from, a row that has already drawn its sleeve gets this for free.
    """

    async def get(self) -> None:
        uri = self.get_argument("uri", "")
        try:
            size = max(80, min(1280, int(self.get_argument("size", "320"))))
        except ValueError:
            size = 320

        if images_mod.split(uri) is None:
            self.set_status(400)
            self.write_json({"error": "expected a tidal: uri"})
            return

        session = self.session_or_503()
        if session is None:
            return

        payload = await self.describe(session, uri, size)
        if payload is None:
            self.set_status(404)
            self.write_json({"error": "nothing known about " + uri})
            return
        self.write_json(payload)


def factory(config, core):
    """Build the request rules Mopidy mounts under /omarchy-tidal/."""
    provider = SessionProvider(config)
    kwargs = {"provider": provider, "core": core, "config": config}
    return [
        (r"/health", HealthHandler, kwargs),
        (r"/auth/status", AuthStatusHandler, kwargs),
        (r"/lyrics", LyricsHandler, kwargs),
        (r"/home", HomeHandler, kwargs),
        (r"/favorite", FavoriteHandler, kwargs),
        (r"/radio", RadioHandler, kwargs),
        (r"/similar", SimilarHandler, kwargs),
        (r"/artist", ArtistHandler, kwargs),
        (r"/album", AlbumHandler, kwargs),
        (r"/format", FormatHandler, kwargs),
        (r"/art", ArtHandler, kwargs),
        (r"/palette", PaletteHandler, kwargs),
        (r"/entity", EntityHandler, kwargs),
        (r"/library", LibraryHandler, kwargs),
        (r"/playlists", PlaylistsHandler, kwargs),
        (r"/playlist", PlaylistEditHandler, kwargs),
    ]
