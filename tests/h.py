# Shared test harness: serves the built app with the simulated Supabase.
import json, pathlib, re
from playwright.sync_api import sync_playwright
import os
ROOT=pathlib.Path(os.environ.get('LD_ROOT','/home/claude/ld/work/public')); T=pathlib.Path('/home/claude/ld/t')
SEED=(T/'seed.json').read_text(); QR='data:image/svg+xml;utf-8,'+(T/'qr.svg').read_text()
FAKE=(T/'fakesb.js').read_text(); XLSX=(T/'node_modules/xlsx/dist/xlsx.full.min.js').read_text()
BASE='http://ld.test/'
def route(r):
    u=r.request.url
    if u.startswith(BASE):
        p=u[len(BASE):].split('?')[0].split('#')[0] or 'index.html'
        if p=='config.js': return r.fulfill(body='window.LD_CONFIG={SUPABASE_URL:"https://demo.supabase.co",SUPABASE_ANON_KEY:"x"};',content_type='application/javascript')
        f=ROOT/p
        return r.fulfill(body=f.read_bytes(),content_type='text/html' if p.endswith('.html') else 'application/javascript') if f.exists() else r.fulfill(status=404,body='')
    if 'supabase-js' in u: return r.fulfill(body='window.__SEED='+SEED+';window.__QR='+json.dumps(QR)+';'+FAKE,content_type='application/javascript')
    if 'xlsx' in u: return r.fulfill(body=XLSX,content_type='application/javascript')
    return r.abort()
def page(br, user=None, w=1440, h=900, ls=None, aal='aal1'):
    ctx=br.new_context(viewport={'width':w,'height':h},device_scale_factor=1,accept_downloads=True)
    ctx.route('**/*',route); pg=ctx.new_page(); pg.errors=[]
    pg.on('pageerror',lambda e:pg.errors.append(str(e))); pg.on('console',lambda m:pg.errors.append(m.text) if m.type=='error' and 'net::ERR' not in m.text and 'Failed to load resource' not in m.text else None)
    store=dict(ls or {})
    if user: store['fake.session']={'email':user,'aal':aal,'at':'2026-11-15T06:00:00Z'}
    pg.add_init_script("window.__ESCCLOSE=true;const __ls=%s;if(!sessionStorage.getItem('seeded')){for(const k in __ls)localStorage.setItem(k,JSON.stringify(__ls[k]));sessionStorage.setItem('seeded','1')}"%json.dumps(store))
    pg.goto(BASE); return pg
def ready(pg):
    pg.wait_for_function("typeof S!=='undefined'&&S.leads&&S.leads.length>0||document.querySelector('#signin')||document.querySelector('.mfas')||/user list|identify/.test(document.body.innerText)",timeout=20000); pg.wait_for_timeout(350)
USERS={'sup':'sup@demo.test','lm':'lm@demo.test','mg':'mg@demo.test','sales':'sales@demo.test','amc':'amc@demo.test'}
