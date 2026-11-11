"""The web page a poster's QR code opens. Plain HTML, no scripts, readable on any phone. It shows the
gathering and counts, never anyone's name but the host's first name and, once you're in, your own."""

from dataclasses import dataclass
from datetime import datetime
from html import escape
from urllib.parse import quote
from zoneinfo import ZoneInfo

from app.config import settings
from app.models import Gathering

PAPER = "#F6F2EA"
INK = "#16141B"
MUTED = "#6E6878"
ACCENT = "#FF5B3A"

MESSAGES = {
    "in": "You're in. See you there.",
    "out": "Got it, you're out. Change your mind any time.",
    "name": "Just a first name, letters only.",
    "full": "It's full. Get the app to hear when a spot opens.",
    "webfull": "The spots for the web are taken. The rest are kept for people on the app: get it below.",
    "slow": "That's a lot of sign-ups from one place. Try again in a bit.",
    "over": "This one's over.",
    "off": "This one isn't on right now.",
}


@dataclass
class PageState:
    code: str
    gathering: Gathering
    tz: str
    weekly: bool
    retired: bool
    ended: bool
    my_name: str | None
    message: str | None
    now: datetime


def clock(dt: datetime) -> str:
    """6:30 PM, or 6 PM on the hour."""
    h = dt.strftime("%I").lstrip("0")
    m = dt.strftime("%M")
    return f"{h}{'' if m == '00' else ':' + m} {dt.strftime('%p')}"


def when_line(g: Gathering, tz: str, weekly: bool) -> str:
    local = g.starts_at.astimezone(ZoneInfo(tz))
    if weekly:
        return f"Every {local.strftime('%A')} · {clock(local)}"
    return f"{local.strftime('%a, %b')} {local.day} · {clock(local)}"


def date_line(g: Gathering, tz: str) -> str:
    z = ZoneInfo(tz)
    s, e = g.starts_at.astimezone(z), g.ends_at.astimezone(z)
    return f"{s.strftime('%A, %B')} {s.day}, {clock(s)} to {clock(e)}"


def first_name(display_name: str) -> str:
    return (display_name.split() or ["the host"])[0]


def count_line(g: Gathering) -> str:
    going = g.going
    if g.capacity > 0:
        left = max(0, g.capacity - going)
        spots = "It's full" if left == 0 else f"{left} spot{'' if left == 1 else 's'} left"
        return f"{going} in · {spots}"
    return f"{going} in so far"


def seats(g: Gathering) -> str:
    if not 0 < g.capacity <= 40:
        return ""
    taken = min(g.going, g.capacity)
    dots = "".join(f'<span class="seat{" taken" if i < taken else ""}"></span>' for i in range(g.capacity))
    return f'<div class="seats" aria-hidden="true">{dots}</div>'


def maps_url(g: Gathering) -> str:
    return f"https://maps.apple.com/?daddr={g.lat},{g.lon}&q={quote(g.place_name)}&dirflg=w"


def render(st: PageState) -> str:
    g = st.gathering
    e = escape
    action = f"/p/{e(st.code)}"
    host = e(first_name(g.host.display_name))
    full = g.capacity > 0 and g.going >= g.capacity

    if st.retired:
        join = '<p class="note">The host took this poster down.</p>'
    elif g.cancelled_at is not None:
        day = g.starts_at.astimezone(ZoneInfo(st.tz)).strftime("%A")
        join = (
            f'<p class="note">Off this week. Back next {e(day)}.</p>'
            if st.weekly
            else '<p class="note">The host called this one off.</p>'
        )
    elif st.ended:
        join = '<p class="note">This one\'s over.</p>'
    elif st.my_name:
        join = f"""
<p class="youre-in">You're in, {e(st.my_name)}.</p>
<form method="post" action="{action}/out"><button class="quiet" type="submit">Can't make it</button></form>"""
    elif full:
        join = '<p class="note">It\'s full right now.</p>'
    else:
        join = f"""
<form method="post" action="{action}/in" class="join">
  <label for="first_name">Your first name</label>
  <input id="first_name" name="first_name" autocomplete="given-name" maxlength="30" required>
  <div class="hp" aria-hidden="true"><label>Leave this empty <input name="website" tabindex="-1"
    autocomplete="off"></label></div>
  <button type="submit">I'm in</button>
  <p class="fine">Only {host} sees your first name. Everyone else sees a count.</p>
</form>"""

    message = f'<p class="flash">{e(MESSAGES[st.message])}</p>' if st.message in MESSAGES else ""
    details = f'<p class="details">{e(g.details)}</p>' if g.details else ""
    bring = f'<p class="bring"><b>Bring</b> {e(g.bring)}</p>' if g.bring else ""
    if settings.app_download_url:
        get_app = f'<a class="button dark" href="{e(settings.app_download_url)}">Get Let\'s Go</a>'
    else:
        get_app = f'<p class="fine">Let\'s Go is in beta on iPhone. Ask {host} for an invite.</p>'

    title = e(g.title)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{title} · Let's Go</title>
<meta property="og:title" content="{title}">
<meta property="og:description" content="{e(when_line(g, st.tz, st.weekly))} · {e(g.place_name)}">
<style>
  :root {{ color-scheme: light; }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; background: {PAPER}; color: {INK};
    font: 17px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif; }}
  main {{ max-width: 480px; margin: 0 auto; padding: 28px 20px 40px; }}
  .when {{ color: {ACCENT}; font-weight: 800; letter-spacing: .08em; text-transform: uppercase;
    font-size: 14px; margin: 0 0 6px; }}
  h1 {{ font-size: 44px; line-height: 1.02; letter-spacing: -.02em; margin: 0 0 10px; font-weight: 900; }}
  .place {{ margin: 0; font-weight: 600; }}
  .date, .fine, .note {{ color: {MUTED}; font-size: 15px; }}
  .date {{ margin: 2px 0 14px; }}
  .details, .bring {{ margin: 0 0 10px; }}
  .count {{ font-size: 22px; font-weight: 800; margin: 18px 0 8px; }}
  .seats {{ display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 18px; }}
  .seat {{ width: 18px; height: 18px; border-radius: 50%; border: 2px solid {INK}; opacity: .35; }}
  .seat.taken {{ background: {ACCENT}; border-color: {ACCENT}; opacity: 1; }}
  .flash {{ background: {INK}; color: {PAPER}; padding: 10px 14px; border-radius: 10px; }}
  .join label {{ display: block; font-weight: 600; margin-bottom: 6px; }}
  input {{ width: 100%; font: inherit; padding: 13px 14px; border-radius: 12px; border: 2px solid {INK};
    background: #fff; color: {INK}; }}
  button, .button {{ display: block; width: 100%; margin-top: 12px; padding: 15px; border: 0;
    border-radius: 14px; background: {ACCENT}; color: #1A0703; font: inherit; font-weight: 800;
    text-align: center; text-decoration: none; cursor: pointer; }}
  .button.dark {{ background: {INK}; color: {PAPER}; }}
  .quiet {{ background: transparent; color: {INK}; border: 2px solid {INK}; }}
  .youre-in {{ font-size: 20px; font-weight: 800; color: {ACCENT}; margin: 0; }}
  .hp {{ position: absolute; left: -10000px; width: 1px; height: 1px; overflow: hidden; }}
  .links a {{ color: {INK}; font-weight: 600; }}
  hr {{ border: 0; border-top: 2px dashed {INK}; opacity: .25; margin: 28px 0 20px; }}
  .app h2 {{ font-size: 20px; margin: 0 0 4px; }}
  .app p {{ margin: 0; }}
  .app p + p {{ margin-top: 10px; }}
  footer {{ margin-top: 28px; color: {MUTED}; font-size: 13px; }}
</style>
</head>
<body>
<main>
  {message}
  <p class="when">{e(when_line(g, st.tz, st.weekly))}</p>
  <h1>{title}</h1>
  <p class="place">{e(g.place_name)}</p>
  <p class="date">{e(date_line(g, st.tz))} · run by {host}</p>
  {details}
  {bring}
  <p class="links"><a href="{e(maps_url(g))}">Walking directions</a></p>
  <p class="count">{e(count_line(g))}</p>
  {seats(g)}
  {join}
  <hr>
  <section class="app">
    <h2>More like this, a walk away</h2>
    <p class="fine">Let's Go is a live map of what's on near you: pickup games, runs, game nights, and
      neighbors cooking. See which friends are going and check in when you show up.</p>
    {get_app}
  </section>
  <footer>Made with Let's Go · Code {e(st.code)}</footer>
</main>
</body>
</html>"""


def not_found() -> str:
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>Let's Go</title></head>
<body style="margin:0;background:{PAPER};color:{INK};font:17px/1.45 -apple-system,Helvetica,Arial,sans-serif">
<main style="max-width:480px;margin:0 auto;padding:40px 20px">
<h1 style="font-size:32px;margin:0 0 8px">No poster with that code</h1>
<p style="color:{MUTED}">Check the letters on the tab: six of them, no zeros or ones.</p>
</main></body></html>"""
