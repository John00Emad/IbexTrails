// 3D terrain map for IbexTrails, driven by the app over a JavaScript bridge.
//
// The app calls:
//   ibex.setLayers(cfg)  base map, overlays, elevation (tile URLs on the
//                        app's local tile server)
//   ibex.setRoute(route) the route line, start/finish and sharp turns
//   ibex.update(live)    you, the group, checkpoints, tracks (about 1/s)
//   ibex.camera(cmd)     fit / center / view
// and hears back through IbexBridge.postMessage: ready, select, gesture.
//
// Names come from other runners over the network, so they are only ever
// set with textContent.
import * as maplibregl from './vendor/maplibre-gl.mjs';

const C = {
  route: '#F26A1B',
  casing: '#1B2330',
  done: '#8A8F98',
  me: '#1C6DD0',
  danger: '#D62839',
  ok: '#2E8B57',
  night: '#1B2330',
  contour: '#5B3A1E',
};

const ICON = {
  flag: '<svg viewBox="0 0 24 24"><path d="M14.4 6L14 4H5v17h2v-7h5.6l.4 2h7V6z"/></svg>',
  nav: '<svg viewBox="0 0 24 24"><path d="M12 2L4.5 20.29l.71.71L12 18l6.79 3 .71-.71z"/></svg>',
  pin: '<svg viewBox="0 0 24 24" fill="#1E7A74"><path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z"/></svg>',
  check: '<svg viewBox="0 0 24 24" fill="#2E8B57"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/></svg>',
  sharp: '<svg viewBox="0 0 24 24" fill="none" stroke="#1B2330" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M8 21V5l9 11"/><path d="M17 10v6h-6"/></svg>',
  uturn: '<svg viewBox="0 0 24 24" fill="none" stroke="#1B2330" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M7 21V10a5 5 0 0 1 10 0v8"/><path d="M13.5 14.5 17 18l3.5-3.5"/></svg>',
};

const SKY = {
  'sky-color': '#7DB7E8',
  'sky-horizon-blend': 0.6,
  'horizon-color': '#F3E3C8',
  'horizon-fog-blend': 0.6,
  'fog-color': '#F3E3C8',
  'fog-ground-blend': 0.3,
  'atmosphere-blend': ['interpolate', ['linear'], ['zoom'], 0, 1, 10, 1, 12, 0],
};

const glyphs = new URL('glyphs/', location.href).href + '{fontstack}/{range}.pbf';

const state = { cfg: null, route: null, live: null, recorded: [] };
let map = null;
let dem = null;
const markers = new Map();

function post(msg) {
  const text = JSON.stringify(msg);
  if (window.IbexBridge) window.IbexBridge.postMessage(text);
  else console.log('[ibex]', text);
}

// ---- Data ------------------------------------------------------------------

const fc = (features) => ({ type: 'FeatureCollection', features });

const lineFc = (coords, properties = {}) =>
  fc(coords && coords.length > 1
    ? [{ type: 'Feature', properties, geometry: { type: 'LineString', coordinates: coords } }]
    : []);

function sourceData() {
  const r = state.route;
  const live = state.live || {};
  let done = [];
  let todo = r ? r.coords : [];
  if (r && live.cut) {
    const cut = [live.cut.lon, live.cut.lat];
    done = r.coords.slice(0, live.cut.i + 1).concat([cut]);
    todo = [cut].concat(r.coords.slice(live.cut.i + 1));
  }
  const ring = live.accuracy;
  return {
    'route-full': lineFc(r ? r.coords : null),
    'route-done': lineFc(done),
    'route-todo': lineFc(todo),
    trail: lineFc(live.trail ? live.trail.coords : null,
      { color: live.trail ? live.trail.color : C.night }),
    recorded: lineFc(state.recorded),
    'off-route': lineFc(live.offRoute),
    accuracy: fc(ring && ring.length > 3
      ? [{ type: 'Feature', properties: {}, geometry: { type: 'Polygon', coordinates: [ring] } }]
      : []),
  };
}

function applyData() {
  if (!map) return;
  for (const [id, data] of Object.entries(sourceData())) {
    try {
      const src = map.getSource(id);
      if (src) src.setData(data);
    } catch {
      // Style still loading; 'style.load' applies the data then.
    }
  }
}

// ---- Style -----------------------------------------------------------------

const rasterSource = (o) => ({ type: 'raster', tiles: [o.tiles], tileSize: 256, maxzoom: o.maxzoom });

const demSource = (d) => ({
  type: 'raster-dem',
  tiles: [d.tiles],
  tileSize: 256,
  maxzoom: d.maxzoom,
  encoding: d.encoding,
});

// Contours are computed here from the elevation tiles, so they need no
// server and work offline wherever the elevation was saved.
function contourTiles(d) {
  const key = `${d.tiles}|${d.encoding}|${d.maxzoom}`;
  if (!dem || dem.key !== key) {
    const source = new globalThis.mlcontour.DemSource({
      url: d.tiles,
      encoding: d.encoding,
      maxzoom: Math.min(d.maxzoom, 14),
      worker: true,
      cacheSize: 100,
      timeoutMs: 15000,
    });
    source.setupMaplibre(maplibregl);
    dem = { key, source };
  }
  return dem.source.contourProtocolUrl({
    multiplier: 1,
    thresholds: {
      // zoom: [minor, major] in metres
      9: [100, 500],
      11: [50, 200],
      12: [20, 100],
      14: [10, 50],
    },
    contourLayer: 'contours',
    elevationKey: 'ele',
    levelKey: 'level',
    extent: 4096,
    buffer: 1,
  });
}

function buildStyle() {
  const cfg = state.cfg;
  const sources = {
    base: rasterSource(cfg.base),
    terrain: demSource(cfg.dem),
  };
  const layers = [
    // Keeps the ground opaque where imagery is missing (offline, not yet
    // loaded). See-through ground shows the edges of other terrain tiles
    // as striped walls.
    { id: 'ground', type: 'background', paint: { 'background-color': '#E8D5B5' } },
    { id: 'base', type: 'raster', source: 'base', paint: { 'raster-fade-duration': 150 } },
  ];
  for (const o of cfg.overlays) {
    if (o.render === 'hillshade') {
      // Its own source: MapLibre renders hillshade and terrain best apart.
      sources.hillshade = demSource(cfg.dem);
      layers.push({
        id: 'hillshade',
        type: 'hillshade',
        source: 'hillshade',
        paint: {
          'hillshade-exaggeration': o.opacity,
          'hillshade-shadow-color': '#2B1D14',
          'hillshade-highlight-color': '#FFF6E6',
          'hillshade-accent-color': '#5C4A3A',
        },
      });
    } else if (o.render === 'contours') {
      sources.contours = { type: 'vector', tiles: [contourTiles(cfg.dem)], maxzoom: 15 };
      layers.push(
        {
          id: 'contour-lines',
          type: 'line',
          source: 'contours',
          'source-layer': 'contours',
          paint: {
            'line-color': C.contour,
            'line-opacity': o.opacity,
            'line-width': ['match', ['get', 'level'], 1, 1.1, 0.5],
          },
        },
        {
          id: 'contour-labels',
          type: 'symbol',
          source: 'contours',
          'source-layer': 'contours',
          filter: ['>', ['get', 'level'], 0],
          layout: {
            'symbol-placement': 'line',
            'symbol-spacing': 320,
            'text-size': 10,
            'text-max-angle': 35,
            'text-field': ['concat', ['number-format', ['get', 'ele'], {}], ' m'],
            'text-font': ['Noto Sans Regular'],
          },
          paint: {
            'text-color': C.contour,
            'text-halo-color': 'rgba(255,255,255,0.85)',
            'text-halo-width': 1.2,
            'text-opacity': o.opacity,
          },
        },
      );
    } else {
      const id = `ov-${o.id}`;
      sources[id] = rasterSource(o);
      layers.push({
        id,
        type: 'raster',
        source: id,
        paint: { 'raster-opacity': o.opacity, 'raster-fade-duration': 150 },
      });
    }
  }

  for (const [id, data] of Object.entries(sourceData())) {
    sources[id] = { type: 'geojson', data };
  }
  const round = { 'line-cap': 'round', 'line-join': 'round' };
  layers.push(
    { id: 'route-done-casing', type: 'line', source: 'route-done', layout: round,
      paint: { 'line-color': '#FFFFFF', 'line-width': 8 } },
    { id: 'route-done', type: 'line', source: 'route-done', layout: round,
      paint: { 'line-color': C.done, 'line-width': 5 } },
    // Dark casing keeps the line visible on pale desert ground.
    { id: 'route-todo-casing', type: 'line', source: 'route-todo', layout: round,
      paint: { 'line-color': C.casing, 'line-opacity': 0.85, 'line-width': 9 } },
    { id: 'route-todo', type: 'line', source: 'route-todo', layout: round,
      paint: { 'line-color': C.route, 'line-width': 5 } },
    { id: 'route-arrows', type: 'symbol', source: 'route-full',
      layout: {
        'symbol-placement': 'line',
        'symbol-spacing': 180,
        'icon-image': 'route-arrow',
        'icon-rotation-alignment': 'map',
        'icon-pitch-alignment': 'map',
      } },
    { id: 'trail', type: 'line', source: 'trail', layout: round,
      paint: { 'line-color': ['get', 'color'], 'line-width': 3, 'line-dasharray': [0.1, 2] } },
    { id: 'recorded', type: 'line', source: 'recorded', layout: round,
      paint: { 'line-color': C.me, 'line-opacity': 0.7, 'line-width': 3 } },
    { id: 'off-route', type: 'line', source: 'off-route',
      paint: { 'line-color': C.danger, 'line-width': 4, 'line-dasharray': [3, 2] } },
    { id: 'accuracy-fill', type: 'fill', source: 'accuracy',
      paint: { 'fill-color': C.me, 'fill-opacity': 0.12 } },
    { id: 'accuracy-line', type: 'line', source: 'accuracy',
      paint: { 'line-color': C.me, 'line-opacity': 0.4, 'line-width': 1 } },
  );

  return {
    version: 8,
    glyphs,
    sources,
    layers,
    terrain: { source: 'terrain', exaggeration: cfg.exaggeration },
    sky: SKY,
  };
}

// Direction arrow along the route, drawn pointing along the line.
function arrowImage() {
  const r = 2;
  const s = 18 * r;
  const canvas = document.createElement('canvas');
  canvas.width = s;
  canvas.height = s;
  const g = canvas.getContext('2d');
  g.beginPath();
  g.arc(s / 2, s / 2, s / 2 - 1.5 * r, 0, Math.PI * 2);
  g.fillStyle = C.route;
  g.fill();
  g.lineWidth = 1.5 * r;
  g.strokeStyle = C.casing;
  g.stroke();
  g.beginPath();
  g.moveTo(s * 0.74, s / 2);
  g.lineTo(s * 0.34, s * 0.28);
  g.lineTo(s * 0.45, s / 2);
  g.lineTo(s * 0.34, s * 0.72);
  g.closePath();
  g.fillStyle = '#FFFFFF';
  g.fill();
  return { image: g.getImageData(0, 0, s, s), pixelRatio: r };
}

// ---- Markers ---------------------------------------------------------------

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

function svg(markup, transform) {
  const holder = document.createElement('div');
  holder.innerHTML = markup; // constant markup only
  const s = holder.firstChild;
  if (transform) s.style.transform = transform;
  return s;
}

function putMarker(key, lngLat, sig, make, options) {
  let m = markers.get(key);
  if (m && m.sig === sig) {
    m.marker.setLngLat(lngLat);
    return m.marker;
  }
  if (m) m.marker.remove();
  const marker = new maplibregl.Marker({ element: make(), ...options })
    .setLngLat(lngLat)
    .addTo(map);
  markers.set(key, { marker, sig });
  return marker;
}

function prune(prefix, keep) {
  for (const [key, m] of markers) {
    if (key.startsWith(prefix) && !keep.has(key)) {
      m.marker.remove();
      markers.delete(key);
    }
  }
}

function roundIcon(markup, color) {
  const e = el('div', 'ibx-round');
  e.style.background = color;
  e.append(svg(markup));
  return e;
}

function drawRouteMarkers() {
  const r = state.route;
  const keep = new Set();
  if (r) {
    keep.add('r:start');
    putMarker('r:start', r.start, 'start', () => roundIcon(ICON.flag, C.ok), { anchor: 'center' });
    if (r.finish) {
      keep.add('r:finish');
      putMarker('r:finish', r.finish, 'finish', () => roundIcon(ICON.flag, '#1F1F1F'), { anchor: 'center' });
    }
    r.turns.forEach((t, i) => {
      const key = `r:turn:${i}`;
      keep.add(key);
      putMarker(key, [t.lon, t.lat], `${t.uTurn}|${t.right}|${t.label}`, () => {
        const e = el('div', 'ibx-turn');
        e.title = t.label;
        e.append(svg(t.uTurn ? ICON.uturn : ICON.sharp, t.right ? '' : 'scaleX(-1)'));
        return e;
      }, { anchor: 'center' });
    });
  }
  prune('r:', keep);
}

function drawLiveMarkers() {
  const live = state.live || {};
  const keep = new Set();

  (live.pins || []).forEach((p, i) => {
    const key = `l:pin:${i}`;
    keep.add(key);
    putMarker(key, [p.lon, p.lat], `${p.name}|${p.passed}`, () => {
      const e = el('div', 'ibx-pin');
      const label = el('div', 'ibx-pin-label', p.name);
      label.dir = 'auto';
      e.append(label, svg(p.passed ? ICON.check : ICON.pin));
      return e;
    }, { anchor: 'bottom' });
  });

  for (const p of live.people || []) {
    const key = `l:p:${p.id}`;
    keep.add(key);
    putMarker(key, [p.lon, p.lat], `${p.name}|${p.initials}|${p.color}|${p.selected}`, () => {
      const e = el('div', `ibx-person${p.selected ? ' selected' : ''}`);
      const dot = el('div', 'ibx-person-dot', p.initials);
      dot.style.background = p.color;
      const name = el('div', 'ibx-person-name', p.name);
      name.dir = 'auto';
      e.append(dot, name);
      e.addEventListener('click', (ev) => {
        ev.stopPropagation();
        post({ type: 'select', id: p.id });
      });
      return e;
    }, { anchor: 'top', offset: [0, -16] });
  }

  const me = live.me;
  if (me) {
    keep.add('l:me');
    const hasHeading = me.heading != null;
    const marker = putMarker('l:me', [me.lon, me.lat], `${hasHeading}`, () => {
      const e = el('div', 'ibx-me');
      if (hasHeading) e.append(svg(ICON.nav));
      e.append(el('div', 'ibx-me-dot'));
      return e;
    }, { anchor: 'center', rotationAlignment: 'map', pitchAlignment: 'viewport' });
    marker.setRotation(hasHeading ? me.heading : 0);
  }
  prune('l:', keep);
}

// ---- Map -------------------------------------------------------------------

function createMap() {
  map = new maplibregl.Map({
    container: 'map',
    style: buildStyle(),
    center: [0, 20],
    zoom: 2,
    maxPitch: 85,
    attributionControl: false,
    pixelRatio: Math.min(window.devicePixelRatio || 1, 2),
  });
  map.setMissingStyleImageResolver((id) => {
    if (id === 'route-arrow' && !map.hasImage(id)) {
      const { image, pixelRatio } = arrowImage();
      map.addImage(id, image, { pixelRatio });
    }
  });
  map.on('style.load', applyData);
  map.on('movestart', (e) => {
    if (e.originalEvent) post({ type: 'gesture' });
  });
  map.on('click', (e) => {
    const target = e.originalEvent && e.originalEvent.target;
    if (target && target.closest && target.closest('.maplibregl-marker')) return;
    post({ type: 'select', id: null });
  });
  map.on('error', (e) => console.warn('[ibex] map error', e && e.error && e.error.message));
  window.ibexMap = map; // for debugging
}

const ibex = {
  setLayers(cfg) {
    state.cfg = cfg;
    if (!map) {
      try {
        createMap();
      } catch (e) {
        // No WebGL on this phone: the app says so and offers 2D.
        map = null;
        post({ type: 'error', message: String((e && e.message) || e) });
        return;
      }
      drawRouteMarkers();
      drawLiveMarkers();
    } else {
      map.setStyle(buildStyle(), { diff: true });
    }
  },

  setRoute(route) {
    state.route = route;
    if (!map) return;
    applyData();
    drawRouteMarkers();
  },

  update(live) {
    // The track grows all run long, so only new points are sent.
    if (live.recorded) {
      if (live.recordedFrom === 0) state.recorded = live.recorded;
      else if (live.recordedFrom === state.recorded.length) state.recorded = state.recorded.concat(live.recorded);
      else post({ type: 'resendTrack' });
    }
    state.live = live;
    if (!map) return;
    applyData();
    drawLiveMarkers();
  },

  camera(c) {
    if (!map) return;
    switch (c.type) {
      case 'fit':
        map.fitBounds(c.bounds, {
          padding: c.padding,
          maxZoom: 16,
          pitch: c.pitch ?? map.getPitch(),
          bearing: map.getBearing(),
          duration: c.animate ? 600 : 0,
        });
        break;
      case 'center':
        map.easeTo({
          center: [c.lon, c.lat],
          zoom: Math.max(map.getZoom(), c.minZoom ?? 0),
          pitch: c.pitch ?? map.getPitch(),
          duration: c.animate === false ? 0 : 500,
        });
        break;
      case 'view':
        map.easeTo({ pitch: c.pitch, bearing: c.bearing ?? map.getBearing(), duration: 600 });
        break;
      case 'toggleTilt':
        // Tilted: back to flat, north up. Flat: tilt for the 3D look.
        map.easeTo(map.getPitch() > 15
          ? { pitch: 0, bearing: 0, duration: 600 }
          : { pitch: 60, duration: 600 });
        break;
    }
  },

  // Camera state, for the app's tilt button.
  view() {
    return map ? { pitch: map.getPitch(), bearing: map.getBearing(), zoom: map.getZoom() } : null;
  },
};

window.ibex = ibex;
post({ type: 'ready' });
