#!/usr/bin/env python3
"""Writes the app's two map styles (MapLibre style JSON) from one description.

    python3 scripts/map-style.py

Paperwhite: paper with faint buildings, white streets with hairline casings, pale water and
parks, small upright grey labels, no POIs and no colour but what's ours. Tiles and fonts
come from OpenFreeMap (OpenStreetMap data in the OpenMapTiles schema, free, no key).
Writes ios/LetsGo/Resources/paperwhite-light.json and paperwhite-dark.json; commit both.
"""
import json
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "ios" / "LetsGo" / "Resources"

LIGHT = {
    "paper": "#F4F2EC",
    "block": "#ECE9E1",
    "building_edge": "#E5E1D7",
    "park": "#E6E9DF",
    "water": "#E7EAEA",
    "water_line": "#DCE1E2",
    "street": "#FFFFFF",
    "major": "#FFFFFF",
    "casing": "#D9D5CB",
    "major_casing": "#CFCABE",
    "path": "#DDD9CF",
    "rail": "#D9D5CB",
    "label": "#8C877C",
    "place": "#6E695F",
}

DARK = {
    "paper": "#1C1C1A",
    "block": "#22221F",
    "building_edge": "#262623",
    "park": "#20241F",
    "water": "#1F2425",
    "water_line": "#272E30",
    "street": "#33322E",
    "major": "#403E39",
    "casing": "#2A2926",
    "major_casing": "#2E2D29",
    "path": "#2E2D29",
    "rail": "#34332F",
    "label": "#9A958A",
    "place": "#C9C4B8",
}

FONT = ["Noto Sans Regular"]
NAME = ["coalesce", ["get", "name_en"], ["get", "name:latin"], ["get", "name"]]
LINES = ["match", ["geometry-type"], ["LineString", "MultiLineString"], True, False]
POLYGONS = ["match", ["geometry-type"], ["Polygon", "MultiPolygon"], True, False]
NOT_TUNNEL = ["!=", ["get", "brunnel"], "tunnel"]


def width(*stops):
    """An exponential line width by zoom: width(13, 1, 20, 20)."""
    return ["interpolate", ["exponential", 1.5], ["zoom"], *stops]


def classes(*names):
    return ["match", ["get", "class"], list(names), True, False]


def road(id_, c, kinds, inner, casing, minzoom, inner_color, casing_color):
    filt = ["all", LINES, NOT_TUNNEL, classes(*kinds)]
    common = {"source": "openmaptiles", "source-layer": "transportation", "minzoom": minzoom, "filter": filt}
    return [
        {"id": f"{id_}_casing", "type": "line", **common,
         "layout": {"line-cap": "round", "line-join": "round"},
         "paint": {"line-color": c[casing_color], "line-width": width(*casing)}},
        {"id": f"{id_}", "type": "line", **common,
         "layout": {"line-cap": "round", "line-join": "round"},
         "paint": {"line-color": c[inner_color], "line-width": width(*inner)}},
    ]


def style(c, name):
    halo = {"text-halo-color": c["paper"], "text-halo-width": 1.4, "text-halo-blur": 0.4}
    layers = [
        {"id": "paper", "type": "background", "paint": {"background-color": c["paper"]}},
        {"id": "green", "type": "fill", "source": "openmaptiles", "source-layer": "landcover",
         "filter": ["all", POLYGONS, classes("grass", "wood")],
         "paint": {"fill-color": c["park"], "fill-opacity": 0.7}},
        {"id": "park", "type": "fill", "source": "openmaptiles", "source-layer": "park",
         "filter": POLYGONS, "paint": {"fill-color": c["park"]}},
        {"id": "water", "type": "fill", "source": "openmaptiles", "source-layer": "water",
         "filter": ["all", POLYGONS, NOT_TUNNEL],
         "paint": {"fill-color": c["water"], "fill-outline-color": c["water_line"], "fill-antialias": True}},
        {"id": "waterway", "type": "line", "source": "openmaptiles", "source-layer": "waterway",
         "filter": ["all", LINES, NOT_TUNNEL],
         "paint": {"line-color": c["water_line"], "line-width": width(10, 0.5, 18, 3)}},
        {"id": "blocks", "type": "fill", "source": "openmaptiles", "source-layer": "building", "minzoom": 13,
         "paint": {"fill-color": c["block"], "fill-outline-color": c["building_edge"],
                   "fill-opacity": ["interpolate", ["linear"], ["zoom"], 13, 0, 14.5, 1]}},
        {"id": "path", "type": "line", "source": "openmaptiles", "source-layer": "transportation", "minzoom": 15,
         "filter": ["all", LINES, NOT_TUNNEL, classes("path", "track")],
         "layout": {"line-cap": "round"},
         "paint": {"line-color": c["path"], "line-width": width(15, 0.6, 20, 2), "line-dasharray": [2, 2]}},
        {"id": "rail", "type": "line", "source": "openmaptiles", "source-layer": "transportation", "minzoom": 12,
         "filter": ["all", LINES, NOT_TUNNEL, classes("rail", "transit")],
         "paint": {"line-color": c["rail"], "line-width": width(12, 0.5, 20, 1.5)}},
        *road("street", c, ["minor", "service"], (13, 0.6, 16, 3.5, 20, 22), (13, 1.4, 16, 4.6, 20, 24),
              13, "street", "casing"),
        *road("major", c, ["primary", "secondary", "tertiary", "trunk"], (10, 0.8, 13, 2, 16, 6, 20, 30),
              (10, 1.4, 13, 3, 16, 7.4, 20, 32), 10, "major", "major_casing"),
        *road("motorway", c, ["motorway"], (8, 0.8, 13, 2.6, 16, 7, 20, 32),
              (8, 1.4, 13, 3.6, 16, 8.4, 20, 34), 8, "major", "major_casing"),
        {"id": "water_name", "type": "symbol", "source": "openmaptiles", "source-layer": "water_name",
         "filter": ["match", ["geometry-type"], ["Point", "MultiPoint"], True, False],
         "layout": {"text-field": NAME, "text-font": FONT, "text-size": 11, "text-max-width": 8,
                    "text-letter-spacing": 0.04},
         "paint": {"text-color": c["label"], **halo}},
        {"id": "street_name", "type": "symbol", "source": "openmaptiles", "source-layer": "transportation_name",
         "minzoom": 15, "filter": ["all", LINES, classes("minor", "service")],
         "layout": {"symbol-placement": "line", "text-field": NAME, "text-font": FONT,
                    "text-size": ["interpolate", ["linear"], ["zoom"], 15, 10, 18, 11.5],
                    "text-rotation-alignment": "map", "symbol-spacing": 320},
         "paint": {"text-color": c["label"], **halo}},
        {"id": "major_name", "type": "symbol", "source": "openmaptiles", "source-layer": "transportation_name",
         "minzoom": 13, "filter": ["all", LINES, classes("primary", "secondary", "tertiary", "trunk", "motorway")],
         "layout": {"symbol-placement": "line", "text-field": NAME, "text-font": FONT,
                    "text-size": ["interpolate", ["linear"], ["zoom"], 13, 10, 18, 12],
                    "text-rotation-alignment": "map", "symbol-spacing": 360},
         "paint": {"text-color": c["label"], **halo}},
        {"id": "neighborhood", "type": "symbol", "source": "openmaptiles", "source-layer": "place",
         "minzoom": 11.5, "filter": classes("suburb", "quarter", "neighbourhood"),
         "layout": {"text-field": NAME, "text-font": FONT, "text-max-width": 7, "text-letter-spacing": 0.02,
                    "text-size": ["interpolate", ["linear"], ["zoom"], 12, 12, 16, 14]},
         "paint": {"text-color": c["place"], **halo}},
        {"id": "town", "type": "symbol", "source": "openmaptiles", "source-layer": "place", "maxzoom": 13,
         "filter": classes("city", "town", "village"),
         "layout": {"text-field": NAME, "text-font": FONT, "text-max-width": 8,
                    "text-size": ["interpolate", ["linear"], ["zoom"], 8, 12, 12, 15]},
         "paint": {"text-color": c["place"], **halo}},
    ]
    return {
        "version": 8,
        "name": name,
        "sources": {
            "openmaptiles": {
                "type": "vector",
                "url": "https://tiles.openfreemap.org/planet",
                "attribution": "© OpenStreetMap contributors · OpenFreeMap · © OpenMapTiles",
            }
        },
        "glyphs": "https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf",
        "layers": layers,
    }


if __name__ == "__main__":
    for file, colors, name in [("paperwhite-light.json", LIGHT, "Paperwhite"), ("paperwhite-dark.json", DARK, "Paperwhite dark")]:
        (OUT / file).write_text(json.dumps(style(colors, name), indent=1, ensure_ascii=False) + "\n")
        print("wrote", OUT / file)
