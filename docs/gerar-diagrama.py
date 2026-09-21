#!/usr/bin/env python3
"""Gera docs/arquitetura-multidc.drawio a partir da topologia descrita abaixo.

Mantido como script porque a topologia mudou várias vezes (regiões, zonas, SKU)
e redesenhar à mão a cada ajuste é onde o diagrama desencosta da realidade.
Conferir contra o cluster:  make mdc-status
"""
import pathlib

# ---- topologia (mantenha em sincronia com Makefile e azure-multidc/) --------
VM = "Standard_B2s_v2"
REG = [
    dict(o=0,   rg="rg-tp01-dc1", reg="chilecentral",  dc="dc1", ip="10.10.32",
         vnet="10.10.0.0/16", nodes="10.10.0.0/20", lb="10.10.32.0/24",
         z_rack1=1, z_rack2=2, app=True),
    dict(o=860, rg="rg-tp01-dc2", reg="mexicocentral", dc="dc2", ip="10.20.32",
         vnet="10.20.0.0/16", nodes="10.20.0.0/20", lb="10.20.32.0/24",
         z_rack1=2, z_rack2=3, app=False),
]
ACR = "acrtp01niegmx.azurecr.io"

cells, _id = [], [1]
def nid():
    _id[0] += 1
    return f"n{_id[0]}"
def esc(s):
    s = s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')
    return s.replace('\n', '&lt;br&gt;')
def box(label, x, y, w, h, style):
    i = nid()
    cells.append(f'<mxCell id="{i}" value="{esc(label)}" style="{style}" vertex="1" parent="1">'
                 f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')
    return i
def edge(label, src, tgt, style):
    i = nid()
    cells.append(f'<mxCell id="{i}" value="{esc(label)}" style="{style}" edge="1" parent="1" '
                 f'source="{src}" target="{tgt}"><mxGeometry relative="1" as="geometry"/></mxCell>')
    return i

S_TITLE = "text;html=1;align=left;verticalAlign=middle;fontSize=21;fontStyle=1;fontColor=#263238;"
S_SUB   = "text;html=1;align=left;verticalAlign=middle;fontSize=13;fontColor=#607D8B;"
S_RG    = "rounded=0;html=1;dashed=1;dashPattern=8 8;fillColor=none;strokeColor=#9E9E9E;verticalAlign=top;align=left;spacingLeft=14;spacingTop=8;fontSize=15;fontStyle=1;fontColor=#546E7A;"
S_VNET  = "rounded=0;html=1;fillColor=#EEF4FD;strokeColor=#6C8EBF;verticalAlign=top;align=left;spacingLeft=14;spacingTop=8;fontSize=14;fontStyle=1;fontColor=#1A4B8C;"
S_SNET  = "rounded=0;html=1;fillColor=#FFFFFF;strokeColor=#9AC7E0;dashed=1;dashPattern=5 5;verticalAlign=top;align=left;spacingLeft=12;spacingTop=6;fontSize=12;fontColor=#2E6F95;"
S_AKS   = "rounded=0;html=1;fillColor=#E9F6EA;strokeColor=#82B366;verticalAlign=top;align=left;spacingLeft=12;spacingTop=6;fontSize=13;fontStyle=1;fontColor=#2E6B34;"
S_ZONE  = "rounded=0;html=1;fillColor=#FFF9E6;strokeColor=#D6B656;verticalAlign=top;align=left;spacingLeft=10;spacingTop=6;fontSize=12;fontStyle=1;fontColor=#7A5D00;"
S_POD   = "rounded=1;html=1;fillColor=#DAE8FC;strokeColor=#6C8EBF;fontSize=12;fontColor=#12355B;"
S_APP   = "rounded=1;html=1;fillColor=#D5E8D4;strokeColor=#82B366;fontSize=11;fontColor=#1B5E20;"
S_OFF   = "rounded=1;html=1;fillColor=#F5F5F5;strokeColor=#BDBDBD;dashed=1;fontSize=11;fontColor=#9E9E9E;"
S_LB    = "rounded=1;html=1;fillColor=#FFE6CC;strokeColor=#D79B00;fontSize=12;fontColor=#7A4F00;"
S_ACR   = "rounded=1;html=1;fillColor=#E1D5E7;strokeColor=#9673A6;fontSize=13;fontStyle=1;fontColor=#4A148C;"
S_NOTE  = "rounded=1;html=1;fillColor=#FAFAFA;strokeColor=#CFD8DC;align=left;verticalAlign=top;spacingLeft=16;spacingTop=12;fontSize=12;fontColor=#37474F;"
S_PEER  = "edgeStyle=orthogonalEdgeStyle;html=1;rounded=0;strokeWidth=3;strokeColor=#D79B00;endArrow=classic;startArrow=classic;fontSize=12;fontStyle=1;fontColor=#7A4F00;labelBackgroundColor=#FFFFFF;"
S_LOCAL = "edgeStyle=orthogonalEdgeStyle;html=1;rounded=0;strokeWidth=2;strokeColor=#82B366;endArrow=classic;startArrow=classic;fontSize=11;fontColor=#2E6B34;labelBackgroundColor=#FFFFFF;"
S_LINK  = "edgeStyle=orthogonalEdgeStyle;html=1;rounded=0;dashed=1;strokeColor=#B0BEC5;endArrow=none;"
S_PULL  = "edgeStyle=orthogonalEdgeStyle;html=1;rounded=0;dashed=1;strokeColor=#9673A6;endArrow=classic;fontSize=11;fontColor=#6A4C93;labelBackgroundColor=#FFFFFF;"

box("Cassandra multi-datacenter na Azure", 40, 18, 900, 32, S_TITLE)
box("6 nós · 2 regiões · 2 racks por região · um único anel · RF {dc1: 3, dc2: 3}", 40, 52, 900, 22, S_SUB)
acr = box(f"Azure Container Registry\n{ACR} — imagem do loadgen", 640, 82, 420, 54, S_ACR)

ref = {}
for r in REG:
    o = r["o"]
    box(f"Resource group  {r['rg']}        região  {r['reg']}", 40+o, 168, 760, 800, S_RG)
    box(f"VNet  vnet-{r['dc']}  ·  {r['vnet']}          rede privada da região", 70+o, 230, 700, 708, S_VNET)
    box(f"Subnet  snet-nodes  ·  {r['nodes']}          endereços das VMs, atribuídos pela Azure",
        100+o, 292, 640, 430, S_SNET)
    aks = box(f"Cluster AKS  ·  3 VMs {VM}  ·  zonas {r['z_rack1']} e {r['z_rack2']}",
              130+o, 354, 580, 346, S_AKS)

    box(f"Zona {r['z_rack1']}   —   rack1  (2 nós)", 160+o, 414, 270, 262, S_ZONE)
    p1 = box(f"pod cassandra-rack1-0\n{r['dc']} · rack1", 182+o, 464, 226, 78, S_POD)
    p2 = box(f"pod cassandra-rack1-1\n{r['dc']} · rack1", 182+o, 564, 226, 78, S_POD)

    box(f"Zona {r['z_rack2']}   —   rack2  (1 nó)", 450+o, 414, 240, 262, S_ZONE)
    p3 = box(f"pod cassandra-rack2-0\n{r['dc']} · rack2", 470+o, 464, 200, 78, S_POD)
    if r["app"]:
        box("pod loadgen\ninstância única do cluster\nescreve e lê em LOCAL_QUORUM", 470+o, 564, 200, 78, S_APP)
    else:
        box("pod loadgen  (parado)\nligado só na demo de\nqueda de região", 470+o, 564, 200, 78, S_OFF)

    lbsub = box(f"Subnet  snet-lb  ·  {r['lb']}          caixas postais: um IP fixo por nó",
                100+o, 754, 640, 160, S_SNET)
    lbs = [box(f"Internal LB\n{r['ip']}.{n}" + ("\nSEED" if n < 12 else ""), x+o, 814, 185, 76, S_LB)
           for n, x in ((10, 118), (11, 328), (12, 538))]
    for pod, lb in zip((p1, p2, p3), lbs):
        edge("", pod, lb, S_LINK)
    edge("imagem", acr, aks, S_PULL)
    ref[r["dc"]] = dict(lbsub=lbsub, p1=p1, p3=p3)

edge("dentro do DC: IP do pod\n(prefer_local = true)", ref["dc1"]["p1"], ref["dc1"]["p3"], S_LOCAL)
edge("VNet peering global\nporta 7000 entre os nós:\ngossip  +  replicação de dados",
     ref["dc1"]["lbsub"], ref["dc2"]["lbsub"], S_PEER)

box(
"AS QUATRO FAIXAS DE ENDEREÇO\n"
"    10.10.0.0/20  ·  10.20.0.0/20      as VMs dos clusters — roteáveis entre as regiões pelo peering\n"
"    10.10.32.0/24 ·  10.20.32.0/24     as caixas postais (internal LB) — IP fixo por nó, é o broadcast_address\n"
"    10.244.0.0/16                      os pods — interna a cada cluster e IDÊNTICA nas duas regiões, por isso não serve entre elas\n"
"    10.0.0.0/16                        os Services (ClusterIP) — interna a cada cluster\n"
"\n"
"CADA NÓ TEM DOIS ENDEREÇOS\n"
"    escuta (listen_address) no IP do pod — único endereço que a máquina realmente possui\n"
"    anuncia (broadcast_address) o IP da caixa postal — único endereço que os outros conseguem alcançar\n"
"    prefer_local = true faz vizinho do mesmo DC falar direto pelo IP do pod; só a travessia entre regiões usa a caixa postal\n"
"\n"
"AS ZONAS DIFEREM ENTRE AS REGIÕES\n"
"    dc1 usa as zonas 1 e 2;  dc2 usa as zonas 2 e 3 — a zona 1 de mexicocentral é barrada para esta subscription.\n"
"    Em ambos, a PRIMEIRA zona recebe 2 VMs (rack1) e a segunda recebe 1 (rack2). Teto de cota: 6 vCPUs por região.\n"
"\n"
"POR QUE ISSO TOLERA FALHA\n"
"    RF {dc1: 3, dc2: 3} → cada linha existe 6 vezes.  LOCAL_QUORUM confirma com 2 das 3 réplicas LOCAIS, sem esperar a outra região.\n"
"    Cai um nó → restam 2 de 3.      Cai um rack/zona → réplicas espalhadas entre racks.      Cai uma região → a outra nunca dependeu dela.",
40, 1000, 1620, 268, S_NOTE)

xml = ('<mxfile host="app.diagrams.net" type="device">\n'
       '  <diagram id="infra-multidc" name="Arquitetura multi-DC">\n'
       '    <mxGraphModel dx="1800" dy="1340" grid="0" gridSize="10" guides="1" tooltips="1" connect="1" '
       'arrows="1" fold="1" page="1" pageScale="1" pageWidth="1700" pageHeight="1300" math="0" shadow="0">\n'
       '      <root>\n        <mxCell id="0"/>\n        <mxCell id="1" parent="0"/>\n'
       + "\n".join("        " + c for c in cells) + "\n"
       '      </root>\n    </mxGraphModel>\n  </diagram>\n</mxfile>\n')

p = pathlib.Path(__file__).parent / "arquitetura-multidc.drawio"
p.write_text(xml)
print(f"{p} · {len(cells)} elementos")
