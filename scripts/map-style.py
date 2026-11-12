#!/usr/bin/env python3
"""Writes the app's two map styles (MapLibre style JSON) from one description.

    python3 scripts/map-style.py

Neighborhood color: a map with life in it, from the data the tiles already carry. Warm
cream land with its blocks, every building footprint with a soft offset shadow, green
parks with darker woods, real blue water with a lighter shoreline, white side streets
and warm yellow main roads, upright labels and neighborhood names in small letterspaced
capitals. After dark it's a city at night: deep navy, lit blocks, warm main roads.
No POIs. Tiles and fonts come from OpenFreeMap (OpenStreetMap data in the OpenMapTiles
schema, free, no key). Writes ios/LetsGo/Resources/neighborhood-light.json and
neighborhood-dark.json; commit both.
"""
import json
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "ios" / "LetsGo" / "Resources"

LIGHT = {
    "land": "#F2EEE6",
    "block": "#E9E3D7",
    "building": "#DED5C5",
    "building_shadow": "rgba(60,40,10,0.08)",
    "building_edge": "#D3C9B6",
    "park": "#C8E3B5",
    "wood": "#AFD498",
    "water": "#9DCBEC",
    "shore": "#B8D9F1",
    "minor": "#FFFFFF",
    "minor_casing": "#D9D1C2",
    "major": "#FFE3A3",
    "major_casing": "#EBC777",
    "path": "#D9D1C2",
    "rail": "#CFC6B5",
    "label": "#6A6457",
    "halo": "#F2EEE6",
    "place": "#857B6A",
    "water_label": "#4F7FA6",
}

DARK = {
    "land": "#121A2B",
    "block": "#172134",
    "building": "#1F2B43",
    "building_shadow": "rgba(0,0,0,0.28)",
    "building_edge": "#26334E",
    "park": "#173427",
    "wood": "#1F4733",
    "water": "#0A1222",
    "shore": "#0E1A30",
    "minor": "#2B3755",
    "minor_casing": "#202A44",
    "major": "#4A3D24",
    "major_casing": "#5E4B28",
    "path": "#2B3755",
    "rail": "#2B3755",
    "label": "#8D97B3",
    "halo": "#121A2B",
    "place": "#A8B1C9",
    "water_label": "#5D7398",
}

FONT = ["Noto Sans Regular"]
BOLD = ["Noto Sans Bold"]
NAME = ["coalesce", ["get", "name_en"], ["get", "name:latin"], ["get", "name"]]
LINES = ["match", ["geometry-type"], ["LineString", "MultiLineString"], True, False]
POLYGONS = ["match", ["geometry-type"], ["Polygon", "MultiPolygon"], True, False]
POINTS = ["match", ["geometry-type"], ["Point", "MultiPoint"], True, False]
NOT_TUNNEL = ["!=", ["get", "brunnel"], "tunnel"]


def width(*stops):
    """An exponential line width by zoom: width(13, 1, 20, 20)."""
    return ["interpolate", ["exponential", 1.5], ["zoom"], *stops]


def linear(*stops):
    return ["interpolate", ["linear"], ["zoom"], *stops]


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
    halo = {"text-halo-color": c["halo"], "text-halo-width": 1.4, "text-halo-blur": 0.4}
    layers = [
        {"id": "land", "type": "background", "paint": {"background-color": c["land"]}},
        # City blocks: everything zoned in OSM, a shade under the land.
        {"id": "blocks", "type": "fill", "source": "openmaptiles", "source-layer": "landuse", "minzoom": 11,
         "filter": ["all", POLYGONS, classes("residential", "commercial", "retail", "industrial", "neighbourhood",
                                              "quarter", "suburb", "school", "university", "college", "hospital",
                                              "railway", "garages", "religious")],
         "paint": {"fill-color": c["block"], "fill-opacity": linear(11, 0, 12.5, 1)}},
        {"id": "green", "type": "fill", "source": "openmaptiles", "source-layer": "landcover",
         "filter": ["all", POLYGONS, classes("grass")],
         "paint": {"fill-color": c["park"]}},
        {"id": "park", "type": "fill", "source": "openmaptiles", "source-layer": "park",
         "filter": POLYGONS, "paint": {"fill-color": c["park"]}},
        # Woods and the trees in parks: a deeper green over the park.
        {"id": "wood", "type": "fill", "source": "openmaptiles", "source-layer": "landcover",
         "filter": ["all", POLYGONS, classes("wood", "forest")],
         "paint": {"fill-color": c["wood"], "fill-opacity": 0.85}},
        {"id": "water", "type": "fill", "source": "openmaptiles", "source-layer": "water",
         "filter": ["all", POLYGONS, NOT_TUNNEL],
         "paint": {"fill-color": c["water"], "fill-antialias": True}},
        # A lighter line along the shore, inside the water's edge.
        {"id": "shore", "type": "line", "source": "openmaptiles", "source-layer": "water",
         "filter": ["all", POLYGONS, NOT_TUNNEL],
         "layout": {"line-join": "round"},
         "paint": {"line-color": c["shore"], "line-width": linear(10, 1, 14, 2.5, 18, 5),
                   "line-offset": linear(10, 0.5, 14, 1.25, 18, 2.5), "line-blur": 0.5}},
        {"id": "waterway", "type": "line", "source": "openmaptiles", "source-layer": "waterway",
         "filter": ["all", LINES, NOT_TUNNEL],
         "paint": {"line-color": c["water"], "line-width": width(10, 0.6, 18, 4)}},
        # Every footprint with a soft shadow down and to the right.
        {"id": "building_shadow", "type": "fill", "source": "openmaptiles", "source-layer": "building", "minzoom": 14,
         "paint": {"fill-color": c["building_shadow"], "fill-antialias": False,
                   "fill-translate": linear(14, ["literal", [0.6, 0.6]], 17, ["literal", [1.6, 1.6]], 19, ["literal", [3, 3]]),
                   "fill-opacity": linear(14, 0, 15, 1)}},
        {"id": "building", "type": "fill", "source": "openmaptiles", "source-layer": "building", "minzoom": 13,
         "paint": {"fill-color": c["building"], "fill-outline-color": c["building_edge"],
                   "fill-opacity": linear(13, 0, 14.5, 1)}},
        {"id": "path", "type": "line", "source": "openmaptiles", "source-layer": "transportation", "minzoom": 15,
         "filter": ["all", LINES, NOT_TUNNEL, classes("path", "track")],
         "layout": {"line-cap": "round"},
         "paint": {"line-color": c["path"], "line-width": width(15, 0.7, 20, 2.2), "line-dasharray": [2, 2]}},
        {"id": "rail", "type": "line", "source": "openmaptiles", "source-layer": "transportation", "minzoom": 12,
         "filter": ["all", LINES, NOT_TUNNEL, classes("rail", "transit")],
         "paint": {"line-color": c["rail"], "line-width": width(12, 0.6, 20, 1.8)}},
        *road("street", c, ["minor", "service"], (13, 0.8, 16, 4.2, 20, 24), (13, 1.6, 16, 5.6, 20, 27),
              12.5, "minor", "minor_casing"),
        *road("major", c, ["primary", "secondary", "tertiary", "trunk"], (10, 1, 13, 2.6, 16, 7.5, 20, 34),
              (10, 1.8, 13, 3.8, 16, 9.4, 20, 37), 10, "major", "major_casing"),
        *road("motorway", c, ["motorway"], (8, 1, 13, 3.2, 16, 8.5, 20, 36),
              (8, 1.8, 13, 4.6, 16, 10.4, 20, 39), 8, "major", "major_casing"),
        # The bay and lakes, never a fountain.
        {"id": "water_name", "type": "symbol", "source": "openmaptiles", "source-layer": "water_name",
         "filter": ["all", POINTS, classes("ocean", "sea", "bay", "strait", "lake", "lagoon", "reservoir")],
         "layout": {"text-field": NAME, "text-font": FONT, "text-size": 12, "text-max-width": 8,
                    "text-letter-spacing": 0.04},
         "paint": {"text-color": c["water_label"], "text-halo-color": c["water"], "text-halo-width": 1, "text-halo-blur": 0.5}},
        {"id": "park_name", "type": "symbol", "source": "openmaptiles", "source-layer": "park", "minzoom": 14,
         "filter": POINTS,
         "layout": {"text-field": NAME, "text-font": FONT, "text-size": 11.5, "text-max-width": 7,
                    "text-letter-spacing": 0.02},
         "paint": {"text-color": c["label"], **halo}},
        {"id": "street_name", "type": "symbol", "source": "openmaptiles", "source-layer": "transportation_name",
         "minzoom": 15, "filter": ["all", LINES, classes("minor", "service")],
         "layout": {"symbol-placement": "line", "text-field": NAME, "text-font": FONT,
                    "text-size": linear(15, 10, 18, 11.5), "text-letter-spacing": 0.03,
                    "text-rotation-alignment": "map", "symbol-spacing": 320},
         "paint": {"text-color": c["label"], **halo}},
        {"id": "major_name", "type": "symbol", "source": "openmaptiles", "source-layer": "transportation_name",
         "minzoom": 13, "filter": ["all", LINES, classes("primary", "secondary", "tertiary", "trunk", "motorway")],
         "layout": {"symbol-placement": "line", "text-field": NAME, "text-font": FONT,
                    "text-size": linear(13, 10, 18, 12), "text-letter-spacing": 0.03,
                    "text-rotation-alignment": "map", "symbol-spacing": 360},
         "paint": {"text-color": c["label"], **halo}},
        # Neighborhoods: small letterspaced capitals.
        {"id": "neighborhood", "type": "symbol", "source": "openmaptiles", "source-layer": "place",
         "minzoom": 11.5, "filter": classes("suburb", "quarter", "neighbourhood"),
         "layout": {"text-field": NAME, "text-font": BOLD, "text-transform": "uppercase", "text-max-width": 9,
                    "text-letter-spacing": 0.18, "text-size": linear(12, 10, 16, 11.5)},
         "paint": {"text-color": c["place"], **halo}},
        {"id": "town", "type": "symbol", "source": "openmaptiles", "source-layer": "place", "maxzoom": 13,
         "filter": classes("city", "town", "village"),
         "layout": {"text-field": NAME, "text-font": BOLD, "text-max-width": 8, "text-letter-spacing": 0.04,
                    "text-size": linear(8, 12, 12, 15)},
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
    for file, colors, name in [("neighborhood-light.json", LIGHT, "Neighborhood color"),
                               ("neighborhood-dark.json", DARK, "Neighborhood color, at night")]:
        (OUT / file).write_text(json.dumps(style(colors, name), indent=1, ensure_ascii=False) + "\n")
        print("wrote", OUT / file)
