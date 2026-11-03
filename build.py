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
inject='''<script src="config.js"></script>
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js"></script>
<script src="adapter.js"></script>
<script>'''
i=src.index('<script>\n/* ---------- defaults')
src=src[:i]+inject+src[i+len('<script>'):]
pathlib.Path('public/index.html').write_text(head+src+'\n</body></html>\n')
print('built public/index.html',len(head+src)//1024,'KB')
