const CACHE_NAME = 'lev-v1'

const SHELL_ASSETS = [
  '/',
  '/index.html',
  '/manifest.json',
  '/assets/logo.svg',
  '/assets/icon-192.png',
  '/assets/icon-512.png',
  '/assets/space-mono-700.woff2',
  '/assets/dm-serif-display-400.woff2',
  '/assets/work-sans-400.woff2',
  '/assets/work-sans-600.woff2',
  '/assets/jetbrains-mono-700.woff2'
]

// Install: precache app shell
self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(SHELL_ASSETS))
      .then(() => self.skipWaiting())
  )
})

// Activate: clean old caches
self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  )
})

// Fetch strategy:
// - db.json: network first, fall back to cache
// - covers: cache first, fall back to network (and cache the response)
// - shell assets: cache first, fall back to network
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url)

  if (url.pathname === '/db.json') {
    // Network first for data freshness
    e.respondWith(
      fetch(e.request)
        .then(response => {
          const clone = response.clone()
          caches.open(CACHE_NAME).then(cache => cache.put(e.request, clone))
          return response
        })
        .catch(() => caches.match(e.request))
    )
    return
  }

  if (url.pathname.startsWith('/covers/')) {
    // Cache first for cover images (they rarely change)
    e.respondWith(
      caches.match(e.request).then(cached => {
        if (cached) return cached
        return fetch(e.request).then(response => {
          const clone = response.clone()
          caches.open(CACHE_NAME).then(cache => cache.put(e.request, clone))
          return response
        })
      })
    )
    return
  }

  // Cache first for everything else (shell assets, fonts)
  e.respondWith(
    caches.match(e.request).then(cached => cached || fetch(e.request))
  )
})
