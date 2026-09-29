// Service worker minimo, so para habilitar "instalar como app" (PWA).
// Nao faz cache agressivo: sempre busca da rede, mantendo os dados sempre
// atualizados (essencial aqui, e um painel de dados ao vivo).
self.addEventListener('install', function(e){ self.skipWaiting(); });
self.addEventListener('activate', function(e){ self.clients.claim(); });
self.addEventListener('fetch', function(e){
  e.respondWith(fetch(e.request).catch(function(){
    return new Response('Sem conexão no momento.', {status:503, headers:{'Content-Type':'text/plain'}});
  }));
});
