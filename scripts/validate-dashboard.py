import sys, yaml, json
path = r'C:\Users\dhenke\git\eneg-k8s-infrastructure-v2\kubernetes\environments\dev\monitoring-alerts\vsphere-hosts-dashboard-cm.yaml'
with open(path, 'r', encoding='utf-8') as f:
    docs = list(yaml.safe_load_all(f))
cm = docs[0]
js = cm['data']['vsphere-hosts.json']
try:
    d = json.loads(js)
    npanels = len(d['panels'])
    nvars = len(d['templating']['list'])
    print(f"JSON OK: {npanels} panels, {nvars} variables, uid={d['uid']}")
except json.JSONDecodeError as e:
    print(f"JSON FEHLER: {e}")
    lines = js.split(chr(10))
    s = max(0, e.lineno-3)
    for i in range(s, min(len(lines), e.lineno+2)):
        print(f"{i+1}: {lines[i]}")
