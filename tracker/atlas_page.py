"""The virus atlases: registry/atlas.html (oncolytic viruses) and
registry/atlas-phage.html (phage therapy) and registry/atlas-aav.html (AAV gene
therapy), one page per field, with tabs.

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

# What a phage trial's conditions or title can name, grouped like INDICATIONS.
INFECTIONS = [
    ("Urinary tract", ["urinary", "cystitis", "pyelonephr", "prostat"]),
    ("Wounds, burns and ulcers", ["wound", "burn", "ulcer", "skin and soft", "pressure injur"]),
    ("Lungs and cystic fibrosis", ["cystic fibrosis", "lung", "pneumon", "respiratory", "bronchiect"]),
    ("Bone and joint", ["prosthetic joint", "periprosthetic", "osteomyel", "bone infection", "joint infection",
                        "diabetic foot"]),
    ("Gut and liver", ["shigell", "diarrh", "crohn", "colitis", "bowel", "intestin", "hepatitis"]),
    ("Bloodstream", ["bacteremia", "bacteraemia", "sepsis", "bloodstream", "endocardit"]),
    ("Ear, nose and sinus", ["otitis", "sinusit", "rhinosinus"]),
    ("Colonisation", ["colonis", "coloniz", "carriage"]),
    ("Healthy volunteers", ["healthy"]),
]

# What an AAV program's trials or approvals name, grouped. First match wins,
# so the neuromuscular storage diseases (Pompe) sit with neuromuscular.
AAV_DISEASES = [
    ("Eye", ["retin", "macular", "vision", "choroideremia", "leber", "achromatops", "ocular", "optic neuropathy",
             "eye disease"]),
    ("Blood", ["haemophilia", "hemophilia", "factor viii", "factor ix"]),
    ("Neuromuscular", ["muscular dystrophy", "duchenne", "spinal muscular atrophy", "myopathy", "pompe",
                       "limb-girdle", "limb girdle"]),
    ("Brain and nerves", ["parkinson", "huntington", "rett", "dravet", "decarboxylase", "aadc", "batten",
                          "canavan", "krabbe", "epilep", "dementia", "neuronal ceroid"]),
    ("Metabolic and lysosomal", ["lipoprotein lipase", "mucopolysacchar", "fabry", "gaucher", "glycogen storage",
                                 "ornithine", "phenylketon", "hunter syndrome", "sanfilippo", "wilson"]),
    ("Heart", ["heart failure", "cardiomyopathy", "danon"]),
    ("Hearing", ["hearing", "deaf", "otoferlin"]),
]

# Each field the atlas covers: one page, one tab. The pages share the code
# below; a field picks the programs (by virus role), the hub kinds shown, and
# how trial conditions are grouped.
FIELDS = [
    {"key": "oncolytic", "page": "atlas.html", "tab": "Oncolytic viruses", "title": "Oncolytic virus atlas",
     "role": "oncolytic", "groups": INDICATIONS, "noun": "oncolytic viruses",
     "unit": ["virus", "viruses"], "item": "Virus", "find": "Find a virus, family, cancer\u2026",
     "groups_head": "Trials in",
     "hubs": HUB_KINDS,
     "lead": "joined to their virus family, transgenes, the cancers their trials enrol, routes and shared sponsors",
     "groups_note": "Cancers come from those trials' conditions, grouped."},
    {"key": "phage", "page": "atlas-phage.html", "tab": "Phage therapy", "title": "Phage therapy atlas",
     "role": "phage", "groups": INFECTIONS, "noun": "phage therapies",
     "unit": ["product", "products"], "item": "Product", "find": "Find a product, bacterium, infection\u2026",
     "groups_head": "Trials in",
     "hubs": [("family", "Phage family or class", "#8a7fd6", True),
              ("host", "Target bacterium", "#d4537e", True),
              ("indication", "Infection", "#2fa58c", True),
              ("route", "Route", "#9a9890", False),
              ("sponsor", "Sponsor (2+ products)", "#b07a4a", False)],
     "cluster": "host",
     "lead": "joined to the bacteria they target, their phage family or class, the infections their trials "
             "enrol, routes and shared sponsors",
     "groups_note": "Infections come from those trials' conditions, grouped; they appear once the weekly "
                    "trial snapshot has linked a product's trials."},
    {"key": "aav", "page": "atlas-aav.html", "tab": "AAV gene therapy", "title": "AAV gene therapy atlas",
     "role": "in_vivo_gene_transfer", "virus_family": "Parvoviridae", "groups": AAV_DISEASES,
     "noun": "AAV gene therapies", "family_from": "strain", "family_label": "Capsid",
     "unit": ["product", "products"], "item": "Product", "find": "Find a product, capsid, disease\u2026",
     "groups_head": "Disease area",
     "hubs": [("family", "Capsid", "#8a7fd6", True),
              ("transgene", "Transgene", "#d4537e", False),   # mostly one product each: clutter
              ("indication", "Disease area", "#2fa58c", True),
              ("route", "Route", "#9a9890", True),
              ("sponsor", "Sponsor (2+ products)", "#b07a4a", False)],
     "lead": "joined to their capsid, transgene, the disease areas of their trials and approvals, routes "
             "and shared sponsors",
     "groups_note": "Disease areas come from those trials' conditions and the approvals' indications, grouped. "
                    "Products whose capsid no source states have no capsid link."},
]


def _split(s):
    return [x.strip() for x in (s or "").split(";") if x.strip()]


def _conditions(t):
    try:
        v = json.loads(t.get("conditions") or "[]")
        return [str(c) for c in v] if isinstance(v, list) else []
    except ValueError:
        return []


def indications_of(trials, groups=None, approvals=()):
    """What a set of trials enrols (and approvals cover), as labels from
    groups (INDICATIONS by default: cancers), sorted."""
    groups = INDICATIONS if groups is None else groups
    found = set()
    sources = [[c.lower() for c in _conditions(t)] + [(t.get("brief_title") or "").lower()] for t in trials]
    sources += [[(a.get("indication") or "").lower()] for a in approvals]
    for texts in sources:
        for text in texts:
            for label, frags in groups:
                if any(f in text for f in frags):
                    found.add(label)
                    break
    return sorted(found)


def stage_of(approvals, trials):
    """(key, label): approved, else the highest phase among confirmed trials."""
    if any(a["status"] in ("approved", "conditional") for a in approvals):
        return "approved", "Approved"
    if any(a["status"] == "withdrawn" for a in approvals):   # got there, then left (Glybera)
        return "approved", "Approved, since withdrawn"
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


def field_of(key):
    return next(f for f in FIELDS if f["key"] == key)


def atlas_data(d, field="oncolytic"):
    """{"nodes": [...], "links": [[source id, target id], ...]} for one field's programs."""
    f = field_of(field)
    def in_field(v):
        return v.get("role") == f["role"] and (not f.get("virus_family") or v.get("virus_family") == f["virus_family"])
    programs = [p for p in d["programs"].values()
                if p["status"] == "active" and in_field(d["virus"].get(p["axp_id"], {}))]
    sponsor_count = {}
    for p in programs:
        s = (p.get("sponsor") or "").strip()
        if s:
            sponsor_count[s] = sponsor_count.get(s, 0) + 1
    nodes, links, hubs = [], [], {}
    kinds = {h[0] for h in f["hubs"]}

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
        cancers = indications_of(trials, f["groups"], d["approvals"].get(axp, []))
        node = {"id": axp, "kind": "virus", "label": p["preferred_name"], "stage": stage,
                "stage_label": stage_label, "aka": names[:3], "family": v.get(f.get("family_from", "virus_family")) or "",
                "hosts": _split(v.get("host")) if "host" in kinds else [],
                "transgenes": _split(v.get("transgenes")) if "transgene" in kinds else [], "routes": [_route_label(r) for r in _split(v.get("route"))],
                "cancers": cancers, "sponsor": p.get("sponsor") or "", "trials": len(trials),
                "url": "%s.html" % axp}
        nodes.append(node)
        if node["family"] and "family" in kinds:
            links.append([axp, hub("family", node["family"])])
        for h in node["hosts"]:
            links.append([axp, hub("host", h)])
        for tg in node["transgenes"]:
            links.append([axp, hub("transgene", tg)])
        for r in node["routes"] if "route" in kinds else []:
            links.append([axp, hub("route", r)])
        for c in cancers:
            links.append([axp, hub("indication", c)])
        s = (p.get("sponsor") or "").strip()
        if s and sponsor_count.get(s, 0) >= 2 and "sponsor" in kinds:
            links.append([axp, hub("sponsor", s)])
    # A hub joined to one product connects nothing: it only crowds the map. The
    # product's info panel and the table still list it. Families stay, since a
    # family is part of what each dot is.
    lone = {h["id"] for h in hubs.values() if h["n"] < 2 and h["kind"] != "family"}
    return {"nodes": [n for n in nodes if n["id"] not in lone],
            "links": [l for l in links if l[1] not in lone]}


ATLAS_CSS = """
.atlas-wrap{position:relative;border:1px solid var(--line);border-radius:12px;overflow:hidden;margin:10px 0 6px;
background:radial-gradient(ellipse at 50% 45%,color-mix(in srgb,var(--accent) 7%,var(--bg)) 0%,var(--bg) 70%)}
#atlas{display:block;width:100%;height:min(74vh,760px);touch-action:none;cursor:grab;--fs:11px;--sw:3px}
@media (max-width:600px){#atlas{height:68vh}}
.atlas-bar button{font:inherit;color:var(--fg);background:var(--chip);border:1px solid var(--line);border-radius:6px;
padding:3px 10px;cursor:pointer}
#atlas.dragging{cursor:grabbing}
#atlas line{stroke-opacity:.16;stroke-width:.8;vector-effect:non-scaling-stroke}
#atlas line.on{stroke-opacity:.85;stroke-width:1.6}
#atlas path.terr{stroke-linejoin:round;stroke-linecap:round;fill-opacity:.07;stroke-opacity:.07;pointer-events:none}
#atlas .n{cursor:pointer;outline:none}
#atlas .n:focus-visible circle{stroke:var(--fg);stroke-width:2.5}
#atlas .virus circle{stroke:var(--bg);stroke-width:1.2;vector-effect:non-scaling-stroke}
#atlas .virus.appr circle{filter:url(#atlas-glow)}
#atlas .hub circle{stroke-width:1.8;fill-opacity:.16;vector-effect:non-scaling-stroke}
#atlas text{font:400 var(--fs) system-ui,-apple-system,"Segoe UI",sans-serif;fill:var(--fg);pointer-events:none;
paint-order:stroke;stroke:var(--bg);stroke-width:var(--sw);stroke-linejoin:round}
#atlas text.hubl{font-weight:600}
#atlas text.big{font-weight:700;letter-spacing:.01em}
#atlas text.terrl{font-size:calc(var(--fs) * 1.12);letter-spacing:.04em}
#atlas .dim{opacity:.1}
.atlas-bar{display:flex;flex-wrap:wrap;gap:6px 16px;align-items:center;margin:12px 0 0;font-size:.9rem}
.atlas-bar label{display:inline-flex;align-items:center;gap:5px;cursor:pointer}
.atlas-bar .sw{display:inline-block;width:11px;height:11px;border-radius:50%;border:2px solid}
.atlas-bar input[type=search]{max-width:260px;padding:6px 9px}
.atlas-legend{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:.85rem;color:var(--muted);margin:6px 0 0}
.atlas-legend span{display:inline-flex;align-items:center;gap:5px}
.atlas-legend i{display:inline-block;width:10px;height:10px;border-radius:50%}
#atlas-info{position:absolute;right:10px;top:10px;width:min(320px,calc(100% - 20px));max-height:calc(100% - 20px);
overflow:auto;background:var(--bg);border:1px solid var(--line);border-radius:10px;padding:10px 12px;font-size:.88rem;
box-shadow:0 4px 18px rgba(0,0,0,.25)}
#atlas-info h3{margin:0 0 4px;font-size:1rem}#atlas-info p{margin:4px 0}
#atlas-info .x{float:right;border:0;background:none;color:var(--muted);font-size:1.3rem;cursor:pointer;line-height:1;
padding:0 0 0 8px}
.atlas-help{font-size:.85rem;color:var(--muted);margin:4px 0 0}
.atlas-tabs{display:flex;flex-wrap:wrap;gap:6px;margin:4px 0 12px;border-bottom:1px solid var(--line)}
.atlas-tabs a{padding:6px 12px;border:1px solid transparent;border-bottom:0;border-radius:8px 8px 0 0;
text-decoration:none;color:var(--muted);margin-bottom:-1px}
.atlas-tabs a[aria-current]{color:var(--fg);border-color:var(--line);background:var(--bg);font-weight:600}
@media (max-width:600px){
 .atlas-bar{gap:6px 12px;font-size:.85rem}
 .atlas-bar input[type=search]{max-width:none;flex:1 1 100%}
 #atlas-info{left:8px;right:8px;top:auto;bottom:8px;width:auto;max-height:46%;border-radius:12px}
}
"""

# The force layout and interaction. Kept dependency-free on purpose (no CDN,
# nothing loaded from elsewhere). The SVG's coordinates are the element's own
# pixels, so text is drawn at a fixed on-screen size however far the map is
# zoomed, and the layout's frame takes the screen's shape (tall on a phone).
ATLAS_JS = r"""
(function(){
var root=document.getElementById('atlas'); if(!root) return;
var data=JSON.parse(document.getElementById('atlas-data').textContent);
var cfg=JSON.parse(document.getElementById('atlas-cfg').textContent);
var NS='http://www.w3.org/2000/svg';
var stageColour={}, hubColour={}, shown={};
cfg.stages.forEach(function(s){stageColour[s[0]]=s[2];});
cfg.hubs.forEach(function(h){hubColour[h[0]]=h[2]; shown[h[0]]=h[3];});
var narrow=root.getBoundingClientRect().width<600;
// On a phone, transgenes start hidden: the map is small and they are the busiest layer.
if(narrow && 'transgene' in shown){ shown.transgene=false;
  var tb=document.querySelector('.atlas-bar input[data-kind="transgene"]'); if(tb) tb.checked=false; }
function el(t,a){var e=document.createElementNS(NS,t); for(var k in a) e.setAttribute(k,a[k]); return e;}

// Screen size (viewBox = pixels) and the layout's world, which has the screen's shape.
var SW, SH, LW, LH;
function measure(){ var r=root.getBoundingClientRect(); SW=Math.max(280,r.width||1000); SH=Math.max(260,r.height||700);
  root.setAttribute('viewBox','0 0 '+SW+' '+SH); LW=1000; LH=Math.max(560,Math.min(1900,1000*SH/SW)); }
measure();

var nodes=data.nodes, byId={};
nodes.forEach(function(n,i){byId[n.id]=n; var a=i*2.39996, r=30+Math.sqrt(i)*24;
  n.x=r*Math.cos(a); n.y=r*Math.sin(a)*LH/LW; n.vx=0; n.vy=0; n.nb=[];});
var links=data.links.map(function(l){var s=byId[l[0]], t=byId[l[1]]; s.nb.push(t); t.nb.push(s); return {s:s,t:t};});
function radius(n){return n.kind==='virus' ? (n.stage==='approved'?8:5.5) : 6+Math.sqrt(n.n)*2.6;}
function visible(n){return n.kind==='virus' || shown[n.kind];}
// How each kind of hub pulls: families hold tight (they make the clusters),
// cancers and the rest pull gently across clusters.
// What this tab clusters by: virus family (oncolytic), capsid (AAV, drawn as
// "family") or target bacterium (phage, nearly all one class). That kind of hub
// holds its products tight and gets a territory; the rest pull gently across.
var CL=cfg.cluster||'family';
var PULL={family:[120,0.006],host:[90,0.02],transgene:[120,0.008],indication:[160,0.005],route:[140,0.006],sponsor:[110,0.010]};
PULL[CL]=[50,0.07];
// A product listed under several (a phage cocktail aimed at three bacteria) sits
// in the territory of the first one listed; its other links still show.
function primary(v){ for(var i=0;i<v.nb.length;i++) if(v.nb[i].kind===CL) return v.nb[i]; return null; }
function charge(n){return n.kind==='virus'?1:(n.kind===CL?1+n.n/6:1+n.n/14);}

var view={x:0,y:0,k:1}, g=el('g'), gt=el('g'), gl=el('g'), gn=el('g'), gx=el('g');
var defs=el('defs'), flt=el('filter',{id:'atlas-glow',x:'-100%',y:'-100%',width:'300%',height:'300%'});
flt.appendChild(el('feGaussianBlur',{stdDeviation:'3',result:'b'}));
var mg=el('feMerge'); mg.appendChild(el('feMergeNode',{'in':'b'})); mg.appendChild(el('feMergeNode',{'in':'SourceGraphic'}));
flt.appendChild(mg); defs.appendChild(flt); root.appendChild(defs);
g.appendChild(gt); g.appendChild(gl); g.appendChild(gn); g.appendChild(gx); root.appendChild(g);
links.forEach(function(l){l.el=el('line',{stroke:hubColour[l.t.kind]||'#888'}); gl.appendChild(l.el);});
// A soft territory behind each family of three or more.
var fams=nodes.filter(function(n){return n.kind===CL;}).map(function(f){
  return {hub:f, members:f.nb.filter(function(m){return m.kind==='virus'&&primary(m)===f;}),
          el:gt.appendChild(el('path',{'class':'terr',fill:hubColour[CL],stroke:hubColour[CL]}))};})
  .filter(function(f){return f.members.length>=3;});
var terrOf={}; fams.forEach(function(f){terrOf[f.hub.id]=f;});
var HALO=17;   // half the territory's stroke: how far it reaches past its dots
nodes.forEach(function(n){
  var grp=el('g',{'class':'n '+(n.kind==='virus'?'virus':'hub')+(n.stage==='approved'?' appr':''),tabindex:'0',role:'button','aria-label':n.label});
  var c=el('circle',{r:radius(n)});
  if(n.kind==='virus'){c.setAttribute('fill',stageColour[n.stage]);}
  else {c.setAttribute('stroke',hubColour[n.kind]); c.setAttribute('fill',hubColour[n.kind]);}
  grp.appendChild(c);
  n.text=el('text',{'class':n.kind==='virus'?'':(n.kind===CL||n.n>=8?'hubl big':'hubl')});
  n.text.textContent=n.label; gx.appendChild(n.text); n.el=grp; gn.appendChild(grp);
  grp.addEventListener('pointerdown',function(e){e.stopPropagation(); startDrag(n,e);});
  grp.addEventListener('keydown',function(e){if(e.key==='Enter'||e.key===' '){e.preventDefault(); select(n);}});
  grp.addEventListener('mouseenter',function(){hover=n; draw();});
  grp.addEventListener('mouseleave',function(){if(hover===n){hover=null; draw();}});
});

// Each family gets a home on a ring, its share of the ring by size, so the
// families settle as separate clusters instead of one ball; one-member
// families sit on an outer ring. Cancers and the rest then sit between them.
var home={};
(function(){ var fs=nodes.filter(function(n){return n.kind===CL;}).sort(function(a,b){return b.n-a.n;});
  var big=fs.filter(function(f){return f.n>=3;}), small=fs.filter(function(f){return f.n<3;});
  var tot=big.reduce(function(t,f){return t+Math.sqrt(f.n);},0)||1, a=-Math.PI/2;
  // alternate large and small around the ring so the big ones don't bunch up
  var order=[], lo=0, hi=big.length-1; while(lo<=hi){order.push(big[lo++]); if(lo<=hi) order.push(big[hi--]);}
  order.forEach(function(f){ var share=Math.sqrt(f.n)/tot*2*Math.PI; a+=share/2;
    home[f.id]=[Math.cos(a)*LW*0.30, Math.sin(a)*LH*0.30]; a+=share/2; });
  small.forEach(function(f,i){ var b=-Math.PI/2+(i+0.5)/small.length*2*Math.PI+0.3;
    home[f.id]=[Math.cos(b)*LW*0.44, Math.sin(b)*LH*0.44]; });
  nodes.forEach(function(n){ if(home[n.id]){n.x=home[n.id][0]; n.y=home[n.id][1];} });
  nodes.forEach(function(n){ if(n.kind!=='virus') return; var f=primary(n);
    if(f){n.x=f.x+(Math.random()-0.5)*40; n.y=f.y+(Math.random()-0.5)*40;} });
})();

var alpha=1;
function tick(){
  var vis=nodes.filter(visible), i, j, a, b, dx, dy, d2, d, f;
  for(i=0;i<vis.length;i++){ a=vis[i];
    for(j=i+1;j<vis.length;j++){ b=vis[j]; dx=b.x-a.x; dy=b.y-a.y; d2=dx*dx+dy*dy||0.01; d=Math.sqrt(d2);
      var room=radius(a)+radius(b)+(a.kind==='virus'&&b.kind==='virus'?6:14);
      if(d<room){ f=(room-d)*0.5/d; a.x-=dx*f/2; a.y-=dy*f/2; b.x+=dx*f/2; b.y+=dy*f/2; }
      if(d2>360000) continue; f=-1500*alpha*charge(a)*charge(b)/d2;
      a.vx+=f*dx/d; a.vy+=f*dy/d; b.vx-=f*dx/d; b.vy-=f*dy/d; } }
  links.forEach(function(l){ if(!visible(l.s)||!visible(l.t)) return; var p=PULL[l.t.kind]||[100,0.02];
    if(l.t.kind===CL&&primary(l.s)!==l.t) p=[110,0.012];
    dx=l.t.x-l.s.x; dy=l.t.y-l.s.y; d=Math.sqrt(dx*dx+dy*dy)||0.01; f=(d-p[0])*p[1]*alpha/d;
    l.s.vx+=f*dx; l.s.vy+=f*dy; l.t.vx-=f*dx; l.t.vy-=f*dy; });
  // Pull towards the centre (harder for dots with few visible links, which
  // nothing else holds), inside an ellipse with the screen's shape.
  var ax=LW/2*0.92, ay=LH/2*0.92;
  vis.forEach(function(n){ var deg=0; for(var q=0;q<n.nb.length;q++) if(visible(n.nb[q])) deg++;
    var pull=deg===0?0.05:deg===1?0.012:0.004, ex=n.x/ax, ey=n.y/ay, e=Math.sqrt(ex*ex+ey*ey);
    n.vx-=n.x*pull*alpha*(LH>LW?LH/LW:1); n.vy-=n.y*pull*alpha*(LW>LH?LW/LH:1);
    if(e>1){ n.vx-=n.x*(1-1/e)*0.2; n.vy-=n.y*(1-1/e)*0.2; }
    var h=home[n.id]; if(h){ n.vx+=(h[0]-n.x)*0.05*alpha; n.vy+=(h[1]-n.y)*0.05*alpha; }
    if(n.fixed){n.vx=n.vy=0; return;} n.vx*=0.6; n.vy*=0.6; n.x+=n.vx; n.y+=n.vy; });
  alpha=Math.max(alpha*0.985, 0);
}

// Convex hull (monotone chain) for the family territories.
function hull(pts){ if(pts.length<3) return pts; pts=pts.slice().sort(function(a,b){return a[0]-b[0]||a[1]-b[1];});
  function cr(o,a,b){return (a[0]-o[0])*(b[1]-o[1])-(a[1]-o[1])*(b[0]-o[0]);}
  var lo=[],up=[],i; for(i=0;i<pts.length;i++){while(lo.length>=2&&cr(lo[lo.length-2],lo[lo.length-1],pts[i])<=0)lo.pop(); lo.push(pts[i]);}
  for(i=pts.length-1;i>=0;i--){while(up.length>=2&&cr(up[up.length-2],up[up.length-1],pts[i])<=0)up.pop(); up.push(pts[i]);}
  up.pop(); lo.pop(); return lo.concat(up); }

// Labels: a fixed size on screen, and only where they fit. Priority: what the
// reader is looking at, then approved products, then the biggest hubs.
var hover=null, sel=null, near={}, FS=narrow?12:11, CH=0.6;
function wanted(n){ if(!visible(n)) return -1;
  if(sel&&near[n.id]) return 1000+(n===sel?100:0)+(n.kind==='virus'?0:n.n);
  if(n===hover) return 900;
  if(sel) return -1;
  if(n.kind==='virus') return n.stage==='approved'?500:-1;
  return (n.kind===CL?300:200)+n.n; }
function placeLabels(){
  var cand=nodes.map(function(n){return [wanted(n),n];}).filter(function(c){return c[0]>=0;})
    .sort(function(a,b){return b[0]-a[0];});
  var boxes=[], pad=3, show={}, dots=[];
  nodes.forEach(function(n){ if(!visible(n)) return; var r=radius(n)*view.k+1, sx=view.x+n.x*view.k, sy=view.y+n.y*view.k;
    dots.push([sx-r,sy-r,sx+r,sy+r,n]); });
  function hit(box,own){ var i,o; for(i=0;i<boxes.length;i++){o=boxes[i];
      if(box[0]<o[2]&&box[2]>o[0]&&box[1]<o[3]&&box[3]>o[1]) return true;}
    for(i=0;i<dots.length;i++){o=dots[i]; if(o[4]===own) continue;
      if(box[0]+pad<o[2]&&box[2]-pad>o[0]&&box[1]+pad<o[3]&&box[3]-pad>o[1]) return true;}
    return false; }
  cand.forEach(function(c){ var n=c[1], r=radius(n)*view.k, sx=view.x+n.x*view.k, sy=view.y+n.y*view.k;
    var w=n.label.length*FS*CH, h=FS+2, y0=sy-h/2, f=terrOf[n.id];
    if(f&&f.top&&!(sel&&near[n.id])){            // a cluster with a territory: name it above, else below, it
      var tw=w*1.2, th=h*1.12;                    // these names are bold and a little larger
      var cx=Math.min(Math.max(view.x+f.top[0]*view.k, tw/2+6), SW-tw/2-6);   // slide inward rather than off the edge
      var tries=[['t',view.y+f.top[1]*view.k-4-th],['u',view.y+f.bot[1]*view.k+4]];
      for(var tt=0;tt<2;tt++){ var yy=tries[tt][1], bx=[cx-tw/2-pad,yy-pad,cx+tw/2+pad,yy+th+pad];
        if(bx[0]<=2||bx[2]>=SW-2||bx[1]<=2||bx[3]>=SH-2) continue; var clash=false;
        for(var i=0;i<boxes.length;i++){var o=boxes[i]; if(bx[0]<o[2]&&bx[2]>o[0]&&bx[1]<o[3]&&bx[3]>o[1]){clash=true;break;}}
        if(!clash){ boxes.push(bx); show[n.id]=tries[tt][0]; f.lx=(cx-view.x)/view.k; return; } } }
    // Try right, left, above, then below the dot; keep inside the frame.
    var spots=[['r',sx+r+4,y0],['l',sx-r-4-w,y0],['a',sx-w/2,sy-r-3-h],['b',sx-w/2,sy+r+3]], placed=null;
    for(var t=0;t<spots.length&&!placed;t++){ var x0=spots[t][1], yy=spots[t][2];
      if(x0<6||x0+w*1.05>SW-6||yy<2||yy+h>SH-2) continue;
      var box=[x0-pad,yy-pad,x0+w+pad,yy+h+pad]; if(n===sel||n===hover||!hit(box,n)) placed=[box,spots[t][0]]; }
    if(!placed) return;
    boxes.push(placed[0]); show[n.id]=placed[1]; });
  nodes.forEach(function(n){ var s=show[n.id]; n.text.style.display=s?'':'none'; if(!s) return;
    if(s==='t'||s==='u'){ var f=terrOf[n.id]; n.text.setAttribute('x', f.lx);
      n.text.setAttribute('y', s==='t' ? f.top[1]-6/view.k : f.bot[1]+(4+FS*0.85)/view.k);
      n.text.setAttribute('text-anchor','middle'); n.text.classList.add('terrl');
      n.text.style.fill='color-mix(in srgb,'+hubColour[CL]+' 55%,var(--fg))'; return; }
    n.text.classList.remove('terrl'); n.text.style.fill='';
    var r=radius(n)+4/view.k, k=view.k;
    if(s==='a'||s==='b'){ n.text.setAttribute('x', n.x); n.text.setAttribute('text-anchor','middle');
      n.text.setAttribute('y', s==='a' ? n.y-radius(n)-3/k-FS*0.25/k : n.y+radius(n)+3/k+FS*0.85/k); return; }
    n.text.setAttribute('x', n.x+(s==='r'?r:-r)); n.text.setAttribute('y', n.y+FS*0.35/k);
    n.text.setAttribute('text-anchor', s==='r'?'start':'end'); });
}
function draw(){
  g.setAttribute('transform','translate('+view.x+','+view.y+') scale('+view.k+')');
  root.style.setProperty('--fs', (FS/view.k)+'px'); root.style.setProperty('--sw', (3/view.k)+'px');
  links.forEach(function(l){ var on=visible(l.s)&&visible(l.t); l.el.style.display=on?'':'none';
    if(on){l.el.setAttribute('x1',l.s.x); l.el.setAttribute('y1',l.s.y); l.el.setAttribute('x2',l.t.x); l.el.setAttribute('y2',l.t.y);} });
  nodes.forEach(function(n){ n.el.style.display=visible(n)?'':'none';
    if(visible(n)) n.el.setAttribute('transform','translate('+n.x+','+n.y+')'); });
  fams.forEach(function(f){ var on=visible(f.hub); f.el.style.display=on?'':'none'; if(!on) return;
    var h=hull([[f.hub.x,f.hub.y]].concat(f.members.map(function(m){return [m.x,m.y];})));
    f.el.setAttribute('d','M'+h.map(function(p){return p[0].toFixed(1)+','+p[1].toFixed(1);}).join('L')+'Z');
    f.el.setAttribute('stroke-width', 2*HALO);
    var top=Infinity, bot=-Infinity, sx=0; h.forEach(function(p){top=Math.min(top,p[1]); bot=Math.max(bot,p[1]); sx+=p[0];});
    f.top=[sx/h.length, top-HALO]; f.bot=[sx/h.length, bot+HALO]; });
  placeLabels();
}
// Fit every visible dot into the frame.
function fit(){
  var vis=nodes.filter(visible); if(!vis.length) return;
  var x0=Infinity,x1=-Infinity,y0=Infinity,y1=-Infinity;
  vis.forEach(function(n){var r=radius(n)+8; x0=Math.min(x0,n.x-r); x1=Math.max(x1,n.x+r); y0=Math.min(y0,n.y-r); y1=Math.max(y1,n.y+r);});
  var pad=narrow?10:24, k=Math.min((SW-2*pad)/Math.max(x1-x0,1),(SH-2*pad)/Math.max(y1-y0,1),3);
  view.k=k; view.x=(SW-(x1-x0)*k)/2-x0*k; view.y=(SH-(y1-y0)*k)/2-y0*k;
}
var still=window.matchMedia&&window.matchMedia('(prefers-reduced-motion: reduce)').matches;
for(var w=0; w<420; w++) tick();
fit(); draw();
var running=false, refit=true;
function run(){ if(running||still) {draw(); return;} running=true;
  (function loop(){ tick(); if(refit) fit(); draw();
    if(alpha>0.004) requestAnimationFrame(loop); else {running=false; refit=false;} })(); }
function reheat(x){alpha=Math.max(alpha,x); if(still){for(var w=0;w<300;w++) tick(); if(refit) fit(); draw();} else run();}
run();

function toScreen(e){var r=root.getBoundingClientRect(); return {x:(e.clientX-r.left)*SW/r.width, y:(e.clientY-r.top)*SH/r.height};}
function toWorld(e){var p=toScreen(e); return {x:(p.x-view.x)/view.k, y:(p.y-view.y)/view.k};}
function zoomAt(mx,my,f){var k=Math.min(8,Math.max(0.2,view.k*f));
  view.x=mx-(mx-view.x)*k/view.k; view.y=my-(my-view.y)*k/view.k; view.k=k; draw();}
// Pointers: one finger or the mouse drags a dot or pans; two fingers pinch-zoom.
var pts={}, drag=null, dragFrom=null, pan=null, pinch=null, moved=false;
function count(){return Object.keys(pts).length;}
function startDrag(n,e){pts[e.pointerId]=toScreen(e); if(count()>1){startPinch(); return;}
  drag=n; moved=false; n.fixed=true; dragFrom={x:e.clientX,y:e.clientY}; root.setPointerCapture(e.pointerId); root.classList.add('dragging');}
function startPinch(){ if(drag){drag.fixed=false; drag=null;} pan=null; var p=Object.keys(pts).map(function(k){return pts[k];});
  pinch={d:Math.hypot(p[0].x-p[1].x,p[0].y-p[1].y)||1}; moved=true; }
root.addEventListener('pointerdown',function(e){pts[e.pointerId]=toScreen(e); root.setPointerCapture(e.pointerId);
  if(count()>1){startPinch(); return;}
  pan={x:e.clientX,y:e.clientY,vx:view.x,vy:view.y}; moved=false; root.classList.add('dragging');});
root.addEventListener('pointermove',function(e){ if(!(e.pointerId in pts)) return; pts[e.pointerId]=toScreen(e);
  if(pinch&&count()>1){ var p=Object.keys(pts).map(function(k){return pts[k];}), d=Math.hypot(p[0].x-p[1].x,p[0].y-p[1].y)||1;
    zoomAt((p[0].x+p[1].x)/2,(p[0].y+p[1].y)/2,d/pinch.d); pinch.d=d; return; }
  if(drag){ // a finger always wobbles a little: it's a tap until it has moved a few pixels
    if(!moved&&Math.abs(e.clientX-dragFrom.x)+Math.abs(e.clientY-dragFrom.y)<6) return;
    var w=toWorld(e); drag.x=w.x; drag.y=w.y; moved=true; reheat(0.12); draw();}
  else if(pan){var r=root.getBoundingClientRect(), dx=(e.clientX-pan.x)*SW/r.width, dy=(e.clientY-pan.y)*SH/r.height;
    if(Math.abs(dx)+Math.abs(dy)>4) moved=true; view.x=pan.vx+dx; view.y=pan.vy+dy; draw();}});
function end(e){ delete pts[e.pointerId];
  if(pinch){ if(count()<2) pinch=null; if(!count()) {root.classList.remove('dragging');} return; }
  if(drag){var d=drag; d.fixed=false; drag=null; if(!moved) select(d);}
  else if(pan&&!moved) select(null);
  pan=null; moved=false; root.classList.remove('dragging'); }
root.addEventListener('pointerup',end); root.addEventListener('pointercancel',end);
// Ctrl/Cmd + wheel (and a trackpad pinch, which arrives as one) zooms; a plain
// wheel scrolls the page, so the graph never traps the reader.
root.addEventListener('wheel',function(e){ if(!(e.ctrlKey||e.metaKey)) return; e.preventDefault();
  var p=toScreen(e); zoomAt(p.x,p.y,Math.exp(-e.deltaY*0.01));},{passive:false});
document.getElementById('atlas-in').addEventListener('click',function(){zoomAt(SW/2,SH/2,1.4);});
document.getElementById('atlas-out').addEventListener('click',function(){zoomAt(SW/2,SH/2,1/1.4);});
var rt; window.addEventListener('resize',function(){clearTimeout(rt); rt=setTimeout(function(){measure(); fit(); draw();},150);});

var info=document.getElementById('atlas-info');
function esc(s){return String(s).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];});}
function select(n){
  sel=n; near={}; if(n){near[n.id]=1; n.nb.forEach(function(m){near[m.id]=1;});}
  nodes.forEach(function(m){ m.el.classList.toggle('dim', !!n && !near[m.id]); m.text.classList.toggle('dim', !!n && !near[m.id]); });
  fams.forEach(function(f){ f.el.classList.toggle('dim', !!n && !near[f.hub.id]); });
  links.forEach(function(l){ var on=!!n&&(l.s===n||l.t===n); l.el.classList.toggle('on',on); l.el.classList.toggle('dim',!!n&&!on); });
  // On a phone the panel covers the lower part of the map: bring the choice above it.
  if(n&&narrow){ var sy=view.y+n.y*view.k; if(sy>SH*0.45) view.y+=SH*0.28-sy; }
  draw();
  if(!n){info.hidden=true; return;}
  var h='<button class="x" aria-label="Close">×</button>';
  if(n.kind==='virus'){
    h+='<h3><a href="'+esc(n.url)+'">'+esc(n.label)+'</a></h3>';
    if(n.aka.length) h+='<p class="muted">'+esc(n.aka.join(', '))+'</p>';
    h+='<p><b>'+esc(n.stage_label)+'</b>'+(n.trials?' · '+n.trials+' linked trial'+(n.trials===1?'':'s'):'')+'</p>';
    if(n.family) h+='<p>'+esc(cfg.family_label)+': '+esc(n.family)+'</p>';
    if(n.hosts&&n.hosts.length) h+='<p>Targets: '+esc(n.hosts.join(', '))+'</p>';
    if(n.transgenes.length) h+='<p>Transgenes: '+esc(n.transgenes.join(', '))+'</p>';
    if(n.routes.length) h+='<p>Route: '+esc(n.routes.join(', '))+'</p>';
    if(n.cancers.length) h+='<p>Trials in: '+esc(n.cancers.join(', '))+'</p>';
    if(n.sponsor) h+='<p>Sponsor: '+esc(n.sponsor)+'</p>';
    h+='<p><a href="'+esc(n.url)+'">Open its registry page →</a></p>';
  } else {
    var vs=n.nb.filter(function(m){return m.kind==='virus';}).sort(function(a,b){return a.label.localeCompare(b.label);});
    var kind=cfg.hubs.filter(function(k){return k[0]===n.kind;})[0][1];
    h+='<h3>'+esc(n.label)+'</h3><p class="muted">'+esc(kind)+' · '+vs.length+' '+esc(cfg.unit[vs.length===1?0:1])+'</p><p>'+
      vs.map(function(v){return '<a href="'+esc(v.url)+'">'+esc(v.label)+'</a> <span class="muted">('+esc(v.stage_label)+')</span>';}).join('<br>')+'</p>';
  }
  info.innerHTML=h; info.hidden=false;
  info.querySelector('.x').addEventListener('click',function(){select(null);});
}
document.querySelectorAll('.atlas-bar input[data-kind]').forEach(function(cb){
  cb.addEventListener('change',function(){shown[cb.getAttribute('data-kind')]=cb.checked;
    if(sel&&!visible(sel)) select(null); refit=true; reheat(0.6);});});
var q=document.getElementById('atlas-q');
q.addEventListener('keydown',function(e){ if(e.key!=='Enter') return; e.preventDefault();
  var t=q.value.trim().toLowerCase(); if(!t) {select(null); return;}
  var hit=nodes.filter(function(n){return visible(n)&&(n.label.toLowerCase().indexOf(t)>=0||
    (n.aka||[]).concat(n.hosts||[]).some(function(a){return a.toLowerCase().indexOf(t)>=0;}));})[0];
  if(!hit) return; view.k=Math.max(view.k,1.6); view.x=SW/2-hit.x*view.k; view.y=SH/2-hit.y*view.k; select(hit);});
document.getElementById('atlas-reset').addEventListener('click',function(){select(null); fit(); draw();});
})();
"""


def tabs_html(current, esc):
    return '<nav class="atlas-tabs" aria-label="Atlas">' + "".join(
        '<a href="%s"%s>%s</a>' % (f["page"], ' aria-current="page"' if f["key"] == current else "", esc(f["tab"]))
        for f in FIELDS) + "</nav>"


def atlas_page(d, esc, frame, filter_js, table, field="oncolytic"):
    """One field's atlas page. esc, frame, filter_js and table come from
    site_pages, so the page shares the registry's look and footer."""
    f = field_of(field)
    data = atlas_data(d, field)
    viruses = [n for n in data["nodes"] if n["kind"] == "virus"]
    counts = {}
    for n in viruses:
        counts[n["stage"]] = counts.get(n["stage"], 0) + 1
    cfg = {"stages": STAGES, "hubs": f["hubs"], "unit": f["unit"], "family_label": f.get("family_label", "Family"),
           "cluster": f.get("cluster", "family")}
    as_json = lambda x: json.dumps(x, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
    has_tg = any(h[0] == "transgene" for h in f["hubs"])
    has_host = any(h[0] == "host" for h in f["hubs"])
    body = ["<style>%s</style>" % ATLAS_CSS,
            "<h1>%s</h1>" % esc(f["title"]),
            tabs_html(field, esc),
            '<p class="lead">All %d %s in the registry, %s. Those that share things sit near '
            "each other, so the field's clusters show up on their own. Click a dot to see what it connects to; "
            "drag to rearrange or pan; zoom with the + and &minus; buttons, Ctrl-scroll or a pinch.</p>"
            % (len(viruses), esc(f["noun"]), esc(f["lead"])),
            '<div class="atlas-bar"><input type="search" id="atlas-q" placeholder="%s '
            '(Enter)" aria-label="Find in the atlas">' % esc(f["find"])
            + "".join('<label><input type="checkbox" data-kind="%s"%s> <span class="sw" style="border-color:%s">'
                      "</span>%s</label>" % (k, " checked" if on else "", colour, esc(label))
                      for k, label, colour, on in f["hubs"])
            + '<span><button type="button" id="atlas-in" aria-label="Zoom in">+</button> '
            '<button type="button" id="atlas-out" aria-label="Zoom out">&minus;</button> '
            '<button type="button" id="atlas-reset">Reset</button></span></div>',
            '<div class="atlas-legend">' + "".join(
                '<span><i style="background:%s"></i>%s (%d)</span>' % (colour, esc(label), counts.get(k, 0))
                for k, label, colour in STAGES) + "</div>",
            '<div class="atlas-wrap"><svg id="atlas" role="img" aria-label="Graph of %s and what '
            'they share"></svg><div id="atlas-info" hidden></div></div>' % esc(f["noun"]),
            '<p class="atlas-help">Stage is the furthest a product has got: an approval anywhere, else the highest '
            "phase among its confirmed trials. %s</p>" % esc(f["groups_note"]),
            '<script type="application/json" id="atlas-data">%s</script>' % as_json(data),
            '<script type="application/json" id="atlas-cfg">%s</script>' % as_json(cfg),
            "<script>%s</script>" % ATLAS_JS,
            "<h2>All %s</h2>" % esc(f["noun"]),
            '<div id="filter" hidden><input type="search" placeholder="Filter the table" aria-label="Filter the table">'
            ' <span id="filter-count" class="muted"></span></div>']
    rows = []
    order = {k: i for i, (k, _, _) in enumerate(STAGES)}
    for n in sorted(viruses, key=lambda n: (-order[n["stage"]], n["label"].lower())):
        search = " ".join([n["label"], n["family"], n["stage_label"], n["sponsor"]] + n["aka"] + n["transgenes"]
                          + n["hosts"] + n["routes"] + n["cancers"]).lower()
        cells = [esc(n["family"]), esc(n["stage_label"])] + ([esc(", ".join(n["hosts"]))] if has_host else []) \
            + ([esc(", ".join(n["transgenes"]))] if has_tg else []) \
            + [esc(", ".join(n["routes"])), esc(", ".join(n["cancers"]))]
        rows.append('<tr data-s="%s"><td><a href="%s">%s</a>%s</td>%s</tr>' % (
            esc(search), esc(n["url"]), esc(n["label"]),
            ' <span class="muted">(%s)</span>' % esc(", ".join(n["aka"])) if n["aka"] else "",
            "".join("<td%s>%s</td>" % (" class=nw" if k == 1 else "", c) for k, c in enumerate(cells))))
    body.append(table([f["item"], f.get("family_label", "Family"), "Stage"] + (["Target bacterium"] if has_host else [])
                      + (["Transgenes"] if has_tg else []) + ["Route", f["groups_head"]],
                      rows))
    body.append("<script>%s</script>" % filter_js)
    return frame(f["title"], body, d["meta"], "", [(None, f["title"])])
