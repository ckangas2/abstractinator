"""The oncolytic virus atlas: registry/atlas.html.

A map of the field drawn as a graph. Every oncolytic virus in the registry is a
dot, coloured by how far it has got (approval, else the highest phase among
its confirmed trials). The things viruses share are dots too: virus families,
transgenes, routes, the cancers their trials enrol, and sponsors with more than
one virus. Lines join each virus to what it has, so clusters (the
GM-CSF-armed herpes viruses, the adenovirus lineages, the cancers most viruses
go after) appear on their own. Below the graph, the same viruses as a
searchable table.

Self-contained: the data is embedded as JSON and the layout is a small force
simulation in plain JavaScript, so the page loads nothing from anywhere else.
Built weekly with the other registry pages (site_pages.write_site).
"""

import json

# Cancers a trial's conditions or title can name: (label, lower-case
# fragments). The first label whose fragment matches wins for each condition;
# a trial can still count for several cancers through several conditions.
INDICATIONS = [
    ("Melanoma", ["melanom"]),
    ("Glioma and brain", ["gliom", "glioblastom", "astrocytom", "brain tumo", "brain cancer", "ependymom",
                          "medulloblastom", "dipg", "central nervous system"]),
    ("Neuroblastoma", ["neuroblastom"]),
    ("Bladder", ["bladder", "urothel"]),
    ("Liver", ["hepatocell", "liver", "hepatic", "hcc"]),
    ("Pancreatic", ["pancrea"]),
    ("Head and neck", ["head and neck", "oral cavity", "oropharyn", "nasopharyn", "laryn", "hypopharyn",
                       "squamous cell carcinoma of the head"]),
    ("Lung", ["lung", "nsclc", "sclc"]),
    ("Mesothelioma", ["mesotheliom"]),
    ("Breast", ["breast"]),
    ("Colorectal", ["colorect", "colon", "rectal"]),
    ("Gastric and oesophageal", ["gastric", "stomach", "esophag", "oesophag", "gastroesophag"]),
    ("Prostate", ["prostat"]),
    ("Ovarian", ["ovar", "fallopian"]),
    ("Kidney", ["renal cell", "kidney"]),
    ("Sarcoma", ["sarcom"]),
    ("Peritoneal", ["periton"]),
    ("Blood cancers", ["myeloma", "lymphoma", "leukemi", "leukaemi"]),
    ("Solid tumours (any)", ["solid tumor", "solid tumour", "advanced cancer", "metastatic cancer",
                             "advanced malignan", "solid malignan", "neoplasms"]),
]

STAGES = [  # (key, label, colour), in order
    ("none", "No confirmed trial", "#8f8d86"),
    ("early", "Early phase 1 / phase 1", "#5b9bd5"),
    ("p2", "Phase 2", "#3f9f7f"),
    ("p3", "Phase 3", "#d9822b"),
    ("approved", "Approved", "#e3b341"),
]

HUB_KINDS = [  # (key, label, colour, shown at first)
    ("family", "Virus family", "#8a7fd6", True),
    ("transgene", "Transgene", "#d4537e", True),
    ("indication", "Cancer", "#2fa58c", True),
    ("route", "Route", "#9a9890", False),
    ("sponsor", "Sponsor (2+ viruses)", "#b07a4a", False),
]

PHASE_RANK = {"EARLY_PHASE1": 0.5, "PHASE1": 1, "PHASE2": 2, "PHASE3": 3, "PHASE4": 4}


def _split(s):
    return [x.strip() for x in (s or "").split(";") if x.strip()]


def _conditions(t):
    try:
        v = json.loads(t.get("conditions") or "[]")
        return [str(c) for c in v] if isinstance(v, list) else []
    except ValueError:
        return []


def indications_of(trials):
    """The cancers a set of trials enrols, as INDICATIONS labels (sorted)."""
    found = set()
    for t in trials:
        texts = [c.lower() for c in _conditions(t)] + [(t.get("brief_title") or "").lower()]
        for text in texts:
            for label, frags in INDICATIONS:
                if any(f in text for f in frags):
                    found.add(label)
                    break
    return sorted(found)


def stage_of(approvals, trials):
    """(key, label): approved, else the highest phase among confirmed trials."""
    if any(a["status"] in ("approved", "conditional") for a in approvals):
        return "approved", "Approved"
    best = 0
    for t in trials:
        for p in (t.get("phases") or "").split("/"):
            best = max(best, PHASE_RANK.get(p, 0))
    if best >= 3:
        return "p3", "Phase 3" if best < 4 else "Phase 4"
    if best >= 2:
        return "p2", "Phase 2"
    if best > 0:
        return "early", "Phase 1" if best >= 1 else "Early phase 1"
    return "none", "No confirmed trial"


def _route_label(r):
    return r.replace("_", " ")


def atlas_data(d):
    """{"nodes": [...], "links": [[source id, target id], ...]} for the oncolytic viruses."""
    programs = [p for p in d["programs"].values()
                if p["status"] == "active" and d["virus"].get(p["axp_id"], {}).get("role") == "oncolytic"]
    sponsor_count = {}
    for p in programs:
        s = (p.get("sponsor") or "").strip()
        if s:
            sponsor_count[s] = sponsor_count.get(s, 0) + 1
    nodes, links, hubs = [], [], {}

    def hub(kind, label):
        hid = "%s:%s" % (kind, label.lower())
        if hid not in hubs:
            hubs[hid] = {"id": hid, "kind": kind, "label": label, "n": 0}
            nodes.append(hubs[hid])
        hubs[hid]["n"] += 1
        return hid

    for p in sorted(programs, key=lambda p: p["axp_id"]):
        axp, v = p["axp_id"], d["virus"][p["axp_id"]]
        trials = [t for t in d["trials"].get(axp, []) if t.get("link_status") == "auto"]
        stage, stage_label = stage_of(d["approvals"].get(axp, []), trials)
        names = [a["alias"] for a in d["aliases"].get(axp, []) if a.get("alias_type") in ("code", "brand")]
        cancers = indications_of(trials)
        node = {"id": axp, "kind": "virus", "label": p["preferred_name"], "stage": stage,
                "stage_label": stage_label, "aka": names[:3], "family": v.get("virus_family") or "",
                "transgenes": _split(v.get("transgenes")), "routes": [_route_label(r) for r in _split(v.get("route"))],
                "cancers": cancers, "sponsor": p.get("sponsor") or "", "trials": len(trials),
                "url": "%s.html" % axp}
        nodes.append(node)
        if node["family"]:
            links.append([axp, hub("family", node["family"])])
        for tg in node["transgenes"]:
            links.append([axp, hub("transgene", tg)])
        for r in node["routes"]:
            links.append([axp, hub("route", r)])
        for c in cancers:
            links.append([axp, hub("indication", c)])
        s = (p.get("sponsor") or "").strip()
        if s and sponsor_count.get(s, 0) >= 2:
            links.append([axp, hub("sponsor", s)])
    return {"nodes": nodes, "links": links}


ATLAS_CSS = """
.atlas-wrap{position:relative;border:1px solid var(--line);border-radius:10px;overflow:hidden;margin:10px 0 6px;
background:var(--bg)}
#atlas{display:block;width:100%;height:min(72vh,720px);touch-action:none;cursor:grab}
@media (max-width:600px){#atlas{height:62vh}}
.atlas-bar button{font:inherit;color:var(--fg);background:var(--chip);border:1px solid var(--line);border-radius:6px;
padding:3px 10px;cursor:pointer}
#atlas.dragging{cursor:grabbing}
#atlas line{stroke:var(--muted);stroke-opacity:.22;stroke-width:.7}
#atlas line.on{stroke:var(--accent);stroke-opacity:.8;stroke-width:1.4}
#atlas .n{cursor:pointer}#atlas .n circle{stroke-width:1.5}
#atlas .hub circle{fill:var(--bg)}
#atlas text{font:11px system-ui,-apple-system,"Segoe UI",sans-serif;fill:var(--fg);pointer-events:none;
paint-order:stroke;stroke:var(--bg);stroke-width:3px;stroke-linejoin:round}
#atlas text.hubl{font-weight:600}
#atlas .dim{opacity:.12}
.atlas-bar{display:flex;flex-wrap:wrap;gap:6px 16px;align-items:center;margin:12px 0 0;font-size:.9rem}
.atlas-bar label{display:inline-flex;align-items:center;gap:5px;cursor:pointer}
.atlas-bar .sw{display:inline-block;width:11px;height:11px;border-radius:50%;border:2px solid}
.atlas-bar input[type=search]{max-width:260px;padding:6px 9px}
.atlas-legend{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:.85rem;color:var(--muted);margin:6px 0 0}
.atlas-legend span{display:inline-flex;align-items:center;gap:5px}
.atlas-legend i{display:inline-block;width:10px;height:10px;border-radius:50%}
#atlas-info{position:absolute;right:10px;top:10px;width:min(320px,calc(100% - 20px));max-height:calc(100% - 20px);
overflow:auto;background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:10px 12px;font-size:.88rem;
box-shadow:0 2px 12px rgba(0,0,0,.18)}
#atlas-info h3{margin:0 0 4px;font-size:1rem}#atlas-info p{margin:4px 0}
#atlas-info .x{float:right;border:0;background:none;color:var(--muted);font-size:1.1rem;cursor:pointer;line-height:1}
.atlas-help{font-size:.85rem;color:var(--muted);margin:4px 0 0}
"""

# The force layout and interaction. Kept dependency-free on purpose (no CDN,
# nothing loaded from elsewhere). Coordinates are in a 1000 x 700 world.
ATLAS_JS = r"""
(function(){
var root=document.getElementById('atlas'); if(!root) return;
var data=JSON.parse(document.getElementById('atlas-data').textContent);
var cfg=JSON.parse(document.getElementById('atlas-cfg').textContent);
var NS='http://www.w3.org/2000/svg', W=1000, H=700;
var stageColour={}, hubColour={}, shown={};
cfg.stages.forEach(function(s){stageColour[s[0]]=s[2];});
cfg.hubs.forEach(function(h){hubColour[h[0]]=h[2]; shown[h[0]]=h[3];});
function el(t,a){var e=document.createElementNS(NS,t); for(var k in a) e.setAttribute(k,a[k]); return e;}
var nodes=data.nodes, byId={};
nodes.forEach(function(n,i){byId[n.id]=n; var a=i*2.39996, r=40+Math.sqrt(i)*22;
  n.x=W/2+r*Math.cos(a); n.y=H/2+r*Math.sin(a); n.vx=0; n.vy=0; n.nb=[];});
var links=data.links.map(function(l){var s=byId[l[0]], t=byId[l[1]]; s.nb.push(t); t.nb.push(s); return {s:s,t:t};});
function radius(n){return n.kind==='virus' ? (n.stage==='approved'?8:5.5) : 5+Math.sqrt(n.n)*2.2;}
function visible(n){return n.kind==='virus' || shown[n.kind];}

var view={x:0,y:0,k:1}, g=el('g'), gl=el('g'), gn=el('g');
g.appendChild(gl); g.appendChild(gn); root.appendChild(g);
root.setAttribute('viewBox','0 0 '+W+' '+H);
links.forEach(function(l){l.el=el('line'); gl.appendChild(l.el);});
nodes.forEach(function(n){
  var grp=el('g',{'class':'n '+(n.kind==='virus'?'virus':'hub'),tabindex:'0',role:'button','aria-label':n.label});
  var c=el('circle',{r:radius(n)});
  if(n.kind==='virus'){c.setAttribute('fill',stageColour[n.stage]); c.setAttribute('stroke',stageColour[n.stage]);}
  else {c.setAttribute('stroke',hubColour[n.kind]);}
  grp.appendChild(c);
  var showLabel = n.kind!=='virus' || n.stage==='approved';
  n.text=el('text',{'class':n.kind==='virus'?'':'hubl',dx:radius(n)+3,dy:4});
  n.text.textContent=n.label; if(!showLabel) n.text.style.display='none';
  grp.appendChild(n.text); n.el=grp; gn.appendChild(grp);
  grp.addEventListener('pointerdown',function(e){e.stopPropagation(); startDrag(n,e);});
  grp.addEventListener('keydown',function(e){if(e.key==='Enter'||e.key===' '){e.preventDefault(); select(n);}});
  grp.addEventListener('mouseenter',function(){if(n.kind==='virus'&&!sel) n.text.style.display='';});
  grp.addEventListener('mouseleave',function(){if(n.kind==='virus'&&!sel&&n.stage!=='approved') n.text.style.display='none';});
});

var alpha=1;
function tick(){
  var vis=nodes.filter(visible), i, j, a, b, dx, dy, d2, d, f;
  for(i=0;i<vis.length;i++){ a=vis[i];
    for(j=i+1;j<vis.length;j++){ b=vis[j]; dx=b.x-a.x; dy=b.y-a.y; d2=dx*dx+dy*dy||0.01;
      if(d2>90000) continue; f=-900*alpha/d2; d=Math.sqrt(d2);
      a.vx+=f*dx/d; a.vy+=f*dy/d; b.vx-=f*dx/d; b.vy-=f*dy/d; } }
  links.forEach(function(l){ if(!visible(l.s)||!visible(l.t)) return;
    dx=l.t.x-l.s.x; dy=l.t.y-l.s.y; d=Math.sqrt(dx*dx+dy*dy)||0.01;
    var want=l.t.kind==='indication'?70:55; f=(d-want)*0.04*alpha/d;
    l.s.vx+=f*dx; l.s.vy+=f*dy; l.t.vx-=f*dx; l.t.vy-=f*dy; });
  vis.forEach(function(n){ n.vx+=(W/2-n.x)*0.006*alpha; n.vy+=(H/2-n.y)*0.006*alpha;
    if(n.fixed){n.vx=n.vy=0; return;} n.vx*=0.6; n.vy*=0.6; n.x+=n.vx; n.y+=n.vy; });
  alpha=Math.max(alpha*0.985, 0);
}
function draw(){
  g.setAttribute('transform','translate('+view.x+','+view.y+') scale('+view.k+')');
  links.forEach(function(l){ var on=visible(l.s)&&visible(l.t); l.el.style.display=on?'':'none';
    if(on){l.el.setAttribute('x1',l.s.x); l.el.setAttribute('y1',l.s.y); l.el.setAttribute('x2',l.t.x); l.el.setAttribute('y2',l.t.y);} });
  nodes.forEach(function(n){ n.el.style.display=visible(n)?'':'none';
    if(visible(n)) n.el.setAttribute('transform','translate('+n.x+','+n.y+')'); });
}
var still=window.matchMedia&&window.matchMedia('(prefers-reduced-motion: reduce)').matches;
for(var w=0; w<(still?400:140); w++) tick();
draw();
var running=false;
function run(){ if(running||still) {draw(); return;} running=true;
  (function loop(){ tick(); draw(); if(alpha>0.004) requestAnimationFrame(loop); else running=false; })(); }
function reheat(x){alpha=Math.max(alpha,x); if(still){for(var w=0;w<200;w++) tick(); draw();} else run();}
run();

function toWorld(e){var r=root.getBoundingClientRect(), sx=W/r.width, sy=H/r.height;
  return {x:((e.clientX-r.left)*sx-view.x)/view.k, y:((e.clientY-r.top)*sy-view.y)/view.k};}
var drag=null, pan=null, moved=false;
function startDrag(n,e){drag=n; moved=false; n.fixed=true; root.setPointerCapture(e.pointerId); root.classList.add('dragging');}
root.addEventListener('pointerdown',function(e){pan={x:e.clientX,y:e.clientY,vx:view.x,vy:view.y}; moved=false;
  root.setPointerCapture(e.pointerId); root.classList.add('dragging');});
root.addEventListener('pointermove',function(e){
  if(drag){var p=toWorld(e); drag.x=p.x; drag.y=p.y; moved=true; reheat(0.15); draw();}
  else if(pan){var r=root.getBoundingClientRect(), dx=(e.clientX-pan.x)*W/r.width, dy=(e.clientY-pan.y)*H/r.height;
    if(Math.abs(dx)+Math.abs(dy)>3) moved=true; view.x=pan.vx+dx; view.y=pan.vy+dy; draw();}});
function end(){ if(drag){var d=drag; d.fixed=false; drag=null; if(!moved) select(d);}
  else if(pan&&!moved) select(null);
  pan=null; moved=false; root.classList.remove('dragging'); }
root.addEventListener('pointerup',end); root.addEventListener('pointercancel',end);
function zoomAt(mx,my,f){var k=Math.min(6,Math.max(0.3,view.k*f));
  view.x=mx-(mx-view.x)*k/view.k; view.y=my-(my-view.y)*k/view.k; view.k=k; draw();}
// Ctrl/Cmd + wheel (and a trackpad pinch, which arrives as one) zooms; a plain
// wheel scrolls the page, so the graph never traps the reader.
root.addEventListener('wheel',function(e){ if(!(e.ctrlKey||e.metaKey)) return; e.preventDefault();
  var r=root.getBoundingClientRect(); zoomAt((e.clientX-r.left)*W/r.width,(e.clientY-r.top)*H/r.height,Math.exp(-e.deltaY*0.01));},
  {passive:false});
document.getElementById('atlas-in').addEventListener('click',function(){zoomAt(W/2,H/2,1.4);});
document.getElementById('atlas-out').addEventListener('click',function(){zoomAt(W/2,H/2,1/1.4);});

var info=document.getElementById('atlas-info'), sel=null;
function esc(s){return String(s).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];});}
function select(n){
  sel=n;
  var near={}; if(n){near[n.id]=1; n.nb.forEach(function(m){near[m.id]=1;});}
  nodes.forEach(function(m){ m.el.classList.toggle('dim', !!n && !near[m.id]);
    if(m.kind==='virus') m.text.style.display=(n&&near[m.id])||m.stage==='approved'?'':'none'; });
  links.forEach(function(l){ var on=!!n&&(l.s===n||l.t===n); l.el.classList.toggle('on',on); l.el.classList.toggle('dim',!!n&&!on); });
  if(!n){info.hidden=true; return;}
  var h='<button class="x" aria-label="Close">×</button>';
  if(n.kind==='virus'){
    h+='<h3><a href="'+esc(n.url)+'">'+esc(n.label)+'</a></h3>';
    if(n.aka.length) h+='<p class="muted">'+esc(n.aka.join(', '))+'</p>';
    h+='<p><b>'+esc(n.stage_label)+'</b>'+(n.trials?' · '+n.trials+' linked trial'+(n.trials===1?'':'s'):'')+'</p>';
    if(n.family) h+='<p>Family: '+esc(n.family)+'</p>';
    if(n.transgenes.length) h+='<p>Transgenes: '+esc(n.transgenes.join(', '))+'</p>';
    if(n.routes.length) h+='<p>Route: '+esc(n.routes.join(', '))+'</p>';
    if(n.cancers.length) h+='<p>Trials in: '+esc(n.cancers.join(', '))+'</p>';
    if(n.sponsor) h+='<p>Sponsor: '+esc(n.sponsor)+'</p>';
    h+='<p><a href="'+esc(n.url)+'">Open its registry page →</a></p>';
  } else {
    var vs=n.nb.filter(function(m){return m.kind==='virus';}).sort(function(a,b){return a.label.localeCompare(b.label);});
    var kind=cfg.hubs.filter(function(k){return k[0]===n.kind;})[0][1];
    h+='<h3>'+esc(n.label)+'</h3><p class="muted">'+esc(kind)+' · '+vs.length+' virus'+(vs.length===1?'':'es')+'</p><p>'+
      vs.map(function(v){return '<a href="'+esc(v.url)+'">'+esc(v.label)+'</a> <span class="muted">('+esc(v.stage_label)+')</span>';}).join('<br>')+'</p>';
  }
  info.innerHTML=h; info.hidden=false;
  info.querySelector('.x').addEventListener('click',function(){select(null);});
}
document.querySelectorAll('.atlas-bar input[data-kind]').forEach(function(cb){
  cb.addEventListener('change',function(){shown[cb.getAttribute('data-kind')]=cb.checked;
    if(sel&&!visible(sel)) select(null); reheat(0.6);});});
var q=document.getElementById('atlas-q');
q.addEventListener('keydown',function(e){ if(e.key!=='Enter') return; e.preventDefault();
  var t=q.value.trim().toLowerCase(); if(!t) {select(null); return;}
  var hit=nodes.filter(function(n){return visible(n)&&(n.label.toLowerCase().indexOf(t)>=0||
    (n.aka||[]).some(function(a){return a.toLowerCase().indexOf(t)>=0;}));})[0];
  if(!hit) return; select(hit); view.k=Math.max(view.k,1.6); view.x=W/2-hit.x*view.k; view.y=H/2-hit.y*view.k; draw();});
document.getElementById('atlas-reset').addEventListener('click',function(){view={x:0,y:0,k:1}; select(null); draw();});
})();
"""


def atlas_page(d, esc, frame, filter_js, table):
    """The atlas page. esc, frame, filter_js and table come from site_pages, so
    the page shares the registry's look and footer."""
    data = atlas_data(d)
    viruses = [n for n in data["nodes"] if n["kind"] == "virus"]
    counts = {}
    for n in viruses:
        counts[n["stage"]] = counts.get(n["stage"], 0) + 1
    cfg = {"stages": STAGES, "hubs": HUB_KINDS}
    as_json = lambda x: json.dumps(x, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
    body = ["<style>%s</style>" % ATLAS_CSS,
            "<h1>Oncolytic virus atlas</h1>",
            '<p class="lead">All %d oncolytic viruses in the registry, joined to their virus family, transgenes, '
            "the cancers their trials enrol, routes and shared sponsors. Viruses that share things sit near "
            "each other, so the field's clusters show up on their own. Click a dot to see what it connects to; "
            "drag to rearrange or pan; zoom with the + and &minus; buttons, Ctrl-scroll or a pinch.</p>" % len(viruses),
            '<div class="atlas-bar"><input type="search" id="atlas-q" placeholder="Find a virus, family, cancer… '
            '(Enter)" aria-label="Find in the atlas">'
            + "".join('<label><input type="checkbox" data-kind="%s"%s> <span class="sw" style="border-color:%s">'
                      "</span>%s</label>" % (k, " checked" if on else "", colour, esc(label))
                      for k, label, colour, on in HUB_KINDS)
            + '<span><button type="button" id="atlas-in" aria-label="Zoom in">+</button> '
            '<button type="button" id="atlas-out" aria-label="Zoom out">&minus;</button> '
            '<button type="button" id="atlas-reset">Reset</button></span></div>',
            '<div class="atlas-legend">' + "".join(
                '<span><i style="background:%s"></i>%s (%d)</span>' % (colour, esc(label), counts.get(k, 0))
                for k, label, colour in STAGES) + "</div>",
            '<div class="atlas-wrap"><svg id="atlas" role="img" aria-label="Graph of oncolytic viruses and what '
            'they share"></svg><div id="atlas-info" hidden></div></div>',
            '<p class="atlas-help">Stage is the furthest a virus has got: an approval anywhere, else the highest '
            "phase among its confirmed trials. Cancers come from those trials' conditions, grouped.</p>",
            '<script type="application/json" id="atlas-data">%s</script>' % as_json(data),
            '<script type="application/json" id="atlas-cfg">%s</script>' % as_json(cfg),
            "<script>%s</script>" % ATLAS_JS,
            "<h2>All oncolytic viruses</h2>",
            '<div id="filter" hidden><input type="search" placeholder="Filter the table" aria-label="Filter the table">'
            ' <span id="filter-count" class="muted"></span></div>']
    rows = []
    order = {k: i for i, (k, _, _) in enumerate(STAGES)}
    for n in sorted(viruses, key=lambda n: (-order[n["stage"]], n["label"].lower())):
        search = " ".join([n["label"], n["family"], n["stage_label"], n["sponsor"]] + n["aka"] + n["transgenes"]
                          + n["routes"] + n["cancers"]).lower()
        rows.append('<tr data-s="%s"><td><a href="%s">%s</a>%s</td><td>%s</td><td class=nw>%s</td>'
                    "<td>%s</td><td>%s</td><td>%s</td></tr>" % (
                        esc(search), esc(n["url"]), esc(n["label"]),
                        ' <span class="muted">(%s)</span>' % esc(", ".join(n["aka"])) if n["aka"] else "",
                        esc(n["family"]), esc(n["stage_label"]), esc(", ".join(n["transgenes"])),
                        esc(", ".join(n["routes"])), esc(", ".join(n["cancers"]))))
    body.append(table(["Virus", "Family", "Stage", "Transgenes", "Route", "Trials in"], rows))
    body.append("<script>%s</script>" % filter_js)
    return frame("Oncolytic virus atlas", body, d["meta"], "", [(None, "Oncolytic virus atlas")])
