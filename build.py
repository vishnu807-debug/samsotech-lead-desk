# Builds public/index.html from the Lead Desk app source (lead-desk.html).
import sys,re,pathlib
src=pathlib.Path(sys.argv[1] if len(sys.argv)>1 else 'lead-desk.html').read_text()
title=re.search(r'<title>.*?</title>',src).group(0)
src=src.replace(title,'',1)
head=f'''<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
{title}
<meta name="robots" content="noindex">
<style>:root{{color-scheme:light;padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}}body{{margin:0;font:14px system-ui,-apple-system,"Segoe UI",sans-serif}}img{{max-width:100%}}[hidden]{{display:none!important}}</style>
</head><body>
'''
import hashlib,os
VER=hashlib.md5(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'public','adapter.js'),'rb').read()).hexdigest()[:8]   # the browser fetches adapter.js again whenever it changes
inject='''<script src="config.js"></script>
<script src="vendor/supabase.js"></script>
<script>window.supabase||document.write('<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js"><\\/script>')</script>
<script src="adapter.js?v='''+VER+'''"></script>
<script>'''
import datetime
VSTAMP=datetime.date.today().strftime('%d %b %Y').lstrip('0')+' · build '+hashlib.md5(src.encode()).hexdigest()[:7]   # shown at the bottom of the app so the owner can see which file is live
src=src.replace('__LD_VERSION__',VSTAMP)
i=src.index('<script>\n/* ---------- defaults')
src=src[:i]+inject+src[i+len('<script>'):]
pathlib.Path('public/index.html').write_text(head+src+'\n</body></html>\n')
print('built public/index.html',len(head+src)//1024,'KB')
