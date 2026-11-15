# Regression: every page of every role must show exactly what the previous version showed (old build vs new build).
import sys,os,hashlib,json; sys.path.insert(0,'/home/claude/ld/t')
from h import *
out={}
with sync_playwright() as p:
    br=p.chromium.launch()
    for k,u in USERS.items():
        for w in (1440,390):
            pg=page(br,u,w=w); ready(pg); pg.wait_for_timeout(500)
            tabs=pg.eval_on_selector_all('button[data-tab]','b=>b.filter(x=>!x.hidden).map(x=>x.dataset.tab)')
            for t in tabs:
                pg.evaluate("t=>{S.tab=t;render()}",t); pg.wait_for_timeout(350)
                subs=pg.eval_on_selector_all('#main .mtabs button','b=>b.length') if t in('mgmt','renew') else 0
                for i in range(max(1,subs)):
                    if subs: pg.evaluate("i=>document.querySelectorAll('#main .mtabs button')[i]?.click()",i); pg.wait_for_timeout(300)
                    if t=='set': pg.evaluate("()=>{document.querySelectorAll('#mfaPanel,#backupPanel').forEach(x=>x.remove())}")
                    txt=pg.evaluate("()=>document.querySelector('#main').innerText.replace(/\\s+/g,' ')")
                    if t=='set': txt=re.sub(r'Two-step sign-in|Backup and full export|Backup',' ',txt)
                    out[f'{k}/{w}/{t}/{i}']=[hashlib.md5(txt.encode()).hexdigest(),len(txt),'Something went wrong' in txt]
            # a won lead and an open lead popup, without the stage row
            for id in pg.evaluate("[window.__DEMO.wonNew,window.__DEMO.quote,window.__DEMO.assigned]"):
                if pg.evaluate("id=>!!S.leadMap[id]",id):
                    pg.evaluate("id=>openDrawer(id)",id); pg.wait_for_timeout(250); txt=pg.evaluate("()=>{const d=document.querySelector('#drawerHost').cloneNode(true);d.querySelector('.stages')?.remove();return d.innerText.replace(/\\s+/g,' ')}")
                    out[f'{k}/{w}/lead/{id}']=[hashlib.md5(txt.encode()).hexdigest(),len(txt),False]; pg.evaluate("closeDrawer()")
            out[f'{k}/{w}/errors']=pg.errors[:3]
    br.close()
json.dump(out,open(sys.argv[1],'w'),indent=0); print(len(out),'pages captured;','errors:',[v for k,v in out.items() if k.endswith('errors') and v],'failed renders:',[k for k,v in out.items() if not k.endswith('errors') and v[2]])
