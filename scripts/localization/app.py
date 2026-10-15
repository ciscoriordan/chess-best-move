#!/usr/bin/env python3
"""Reproducible string catalogs: compiler extraction, DeepL drafts, reviewed edits."""
import argparse
from collections import Counter
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

import requests
import yaml

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / 'localization'
RESOURCES = ROOT / 'App/Resources'
TARGETS = {'es':'ES','pt-BR':'PT-BR','fr':'FR','de':'DE','it':'IT','tr':'TR'}
CATALOGS = ['Localizable','AppShortcuts','InfoPlist']
PLACEHOLDER = re.compile(r'%(?:\d+\$)?[-+#0 ]*(?:\d+)?(?:\.\d+)?(?:ll|l|h|z)?[@diufgse]|\$\{[^}]+\}')
CONTEXT = '''Chess Best Move is an iPhone and iPad chess screenshot analysis app. Keep the app name Chess Best Move, Pro, Stockfish, Siri, VoiceOver, TestFlight, App Store, iPhone, iPad, Mac, FEN and chess square coordinates unchanged. Use Apple's official localized names for Photos, Shortcuts, Settings, Control Center, Action button, Back Tap, Apple Account, and purchase controls. Use natural concise interface language, conventional chess terms, and normal capitalization in the target language. Capture means taking a chess piece; screenshot means an image of the screen. Preserve leading and trailing spaces in fragments. Placeholders are runtime values and may be reordered with the sentence.'''


def read(path, default=None):
    return json.loads(path.read_text()) if path.exists() else (default if default is not None else {})


def write(path, data):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(data,ensure_ascii=False,indent=2,sort_keys=True)+'\n')


def identity(catalog,key,index=0):
    return hashlib.sha256(f'{catalog}\0{key}\0{index}'.encode()).hexdigest()[:20]


def extract(sync=False):
    if sync:
        base=ROOT/'build/DD/Build/Intermediates.noindex/ChessBestMove.build/Debug-iphonesimulator'
        files=[]
        for target in ['ChessBestMove','ChessBestMoveShare','ChessBestMoveWidgets']:
            files.extend((base/f'{target}.build/Objects-normal/arm64').glob('*.stringsdata'))
        if not files: raise RuntimeError('Build Debug with scripts/dev/build.sh before extracting.')
        subprocess.run(['xcrun','xcstringstool','sync',str(RESOURCES/'Localizable.xcstrings'),str(RESOURCES/'AppShortcuts.xcstrings'),'--stringsdata',*[str(p) for p in files]],check=True)
    config=yaml.safe_load((ROOT/'project.yml').read_text())
    permission=config['targets']['ChessBestMove']['info']['properties']['NSPhotoLibraryUsageDescription']
    info=read(RESOURCES/'InfoPlist.xcstrings',{'sourceLanguage':'en','strings':{},'version':'1.0'})
    permission_entry=info['strings'].setdefault('NSPhotoLibraryUsageDescription',{'extractionState':'manual','localizations':{}})
    permission_entry['localizations']['en']={'stringUnit':{'state':'translated','value':permission}}
    write(RESOURCES/'InfoPlist.xcstrings',info)
    source={}
    for catalog in CATALOGS:
        path=RESOURCES/f'{catalog}.xcstrings'
        data=read(path)
        for key,item in data['strings'].items():
            # Technical notation and product names are deliberately invariant.
            if not re.search('[A-Za-z]',PLACEHOLDER.sub('',key)) or key in {'Chess Best Move','Pro','FEN','SAN','Stockfish','Stockfish 19','App Store','Nf6','e4','O-O','O-O-O'} or key.startswith('focusSystem='):
                item['shouldTranslate']=False
            if item.get('shouldTranslate') is False or item.get('extractionState')=='stale': continue
            en=item.get('localizations',{}).get('en',{})
            values=en.get('stringSet',{}).get('values') or [en.get('stringUnit',{}).get('value',key)]
            for index,value in enumerate(values):
                source[identity(catalog,key,index)]={'catalog':catalog,'key':key,'index':index,'source':value,'comment':item.get('comment','')}
        write(path,data)
    write(DATA/'source.json',source)
    return source


def protected(value):
    # Number placeholders before translation, so moving one cannot swap runtime arguments.
    counter=0
    def token(match):
        nonlocal counter
        text=match.group()
        if text.startswith('%'):
            counter+=1
            if not re.match(r'%\d+\$',text):text='%'+str(counter)+'$'+text[1:]
        return '<x>'+html.escape(text)+'</x>'
    escaped=html.escape(value)
    return '<text>'+PLACEHOLDER.sub(token,escaped)+'</text>'


def unprotected(value):
    return ''.join(ET.fromstring(value).itertext())


def signature(value):
    # Treat unnumbered placeholders in order, and keep explicit argument positions.
    tokens=[];counter=0
    for match in PLACEHOLDER.finditer(value):
        text=match.group()
        if text.startswith('%'):
            counter+=1
            if not re.match(r'%\d+\$',text):text='%'+str(counter)+'$'+text[1:]
        tokens.append(text)
    return Counter(tokens)


def translate(source,locale):
    path=DATA/'deepl'/f'{locale}.json';saved=read(path)
    pending=[(k,v) for k,v in source.items() if k not in saved or saved[k]['source']!=v['source']]
    token=os.environ.get('DEEPL_API_KEY') or (Path.home()/'.config/chessbestmove/deepl-api-key').read_text().strip()
    for offset in range(0,len(pending),40):
        batch=pending[offset:offset+40]
        payload={'text':[protected(v['source']) for _,v in batch],'source_lang':'EN','target_lang':TARGETS[locale],'tag_handling':'xml','ignore_tags':['x'],'preserve_formatting':True,'context':CONTEXT}
        for attempt in range(4):
            response=requests.post('https://api-free.deepl.com/v2/translate',headers={'Authorization':'DeepL-Auth-Key '+token},json=payload,timeout=90)
            if response.status_code not in {429,500,502,503,504}:break
            time.sleep(2**attempt)
        if not response.ok:raise RuntimeError(f'DeepL failed: HTTP {response.status_code}')
        translated=response.json()['translations']
        if len(translated)!=len(batch):raise RuntimeError('Incomplete translation response')
        for (k,v),item in zip(batch,translated):
            value=unprotected(item['text'])
            if signature(v['source'])!=signature(value): print(f'Needs placeholder review: {locale}, {k}',flush=True)
            saved[k]={'source':v['source'],'translation':value,'translatedAt':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
        write(path,saved)
        print(f'{locale}: {min(offset+len(batch),len(pending))}/{len(pending)}',flush=True)


def build(source, draft=False):
    catalogs={name:read(RESOURCES/f'{name}.xcstrings') for name in CATALOGS}
    # Reset shortcut sets before filling them, independent of hash-key iteration order.
    for entry in catalogs['AppShortcuts']['strings'].values():
        for locale in TARGETS:
            entry.get('localizations',{}).pop(locale,None)
    for locale in TARGETS:
        raw=read(DATA/'deepl'/f'{locale}.json');reviewed=read(DATA/'reviewed'/f'{locale}.json')
        for key,item in source.items():
            review=reviewed.get(key)
            machine=raw.get(key)
            if machine and protected(machine['source'])!=protected(item['source']):raise RuntimeError(f'Stale translation: {locale}, {key}')
            if review and protected(review.get('source',''))!=protected(item['source']):
                raise RuntimeError(f'Stale editorial review: {locale}, {key}')
            if not machine and not review:
                raise RuntimeError(f'Missing translation: {locale}, {key}')
            if not draft and not review:
                raise RuntimeError(f'Editorial review required: {locale}, {key}. Use --draft only for local previews.')
            value=review['translation'] if review else machine['translation']
            if signature(value)!=signature(item['source']):raise RuntimeError(f'Placeholder mismatch: {locale}, {key}')
            entry=catalogs[item['catalog']]['strings'][item['key']]
            target=entry.setdefault('localizations',{}).setdefault(locale,{})
            if item['catalog']=='AppShortcuts':
                shortcut=target.setdefault('stringSet',{'state':'translated','values':[]})
                if not review:shortcut['state']='needs_review'
                values=shortcut['values']
                while len(values)<=item['index']:values.append('')
                values[item['index']]=value
            else:
                target.clear()
                if review and review.get('plural'):
                    forms=review['plural']
                    if set(forms)!={'one','other'} or forms['other']!=value:
                        raise RuntimeError(f'Invalid plural forms: {locale}, {key}')
                    if any(signature(form)!=signature(item['source']) for form in forms.values()):
                        raise RuntimeError(f'Plural placeholder mismatch: {locale}, {key}')
                    # Select by the first numeric argument explicitly. Inferring it from a
                    # sentence with both remaining and total counts chooses ambiguously.
                    target['stringUnit']={'state':'translated','value':'%#@count@'}
                    target['substitutions']={'count':{'argNum':1,'formatSpecifier':'lld','variations':{'plural':{name:{'stringUnit':{'state':'translated','value':form}} for name,form in forms.items()}}}}
                else:
                    target['stringUnit']={'state':'translated' if review else 'needs_review','value':value}
    for name,catalog in catalogs.items():write(RESOURCES/f'{name}.xcstrings',catalog)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('action',choices=['extract','translate','build','sync'])
    parser.add_argument('--locale',choices=list(TARGETS))
    parser.add_argument('--draft',action='store_true',help='Allow unreviewed translations for local previews.')
    args=parser.parse_args()
    source=extract(sync=args.action=='sync')
    print(f'{len(source)} strings, {sum(len(v["source"]) for v in source.values())} source characters',flush=True)
    if args.action=='translate':
        for locale in ([args.locale] if args.locale else TARGETS):translate(source,locale)
    if args.action=='build':build(source,draft=args.draft)
