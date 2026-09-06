#!/usr/bin/env python3
"""Compile the current production helpers with isolated regression harnesses.
No real API calls, credentials, or user document directories are used.
"""
import pathlib, subprocess, tempfile, os
root = pathlib.Path(__file__).resolve().parent.parent
scratch = pathlib.Path(tempfile.mkdtemp(prefix='simpleview-regression-'))
print('Regression artifacts:', scratch, flush=True)
def source(name): return (root/'SimPleview'/name).read_text()
(scratch/'FileMonitor.swift').write_text('import Foundation\nimport Dispatch\nimport Darwin\n' + 'class FileMonitor: NSObject' + source('Managers/DocumentManager.swift').split('class FileMonitor: NSObject',1)[1])
flags = ['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-enable-upcoming-feature','NonisolatedNonsendingByDefault','-module-cache-path',str(scratch/'modules'),'-parse-as-library']
if os.environ.get('SIMPLEVIEW_SANITIZER') in ['thread', 'address']:
    flags += ['-sanitize=' + os.environ['SIMPLEVIEW_SANITIZER']]
def run(name, files):
    subprocess.run(flags + list(map(str,files)) + ['-o',str(scratch/name)],check=True,cwd=root)
    subprocess.run([str(scratch/name),str(scratch)],check=True,cwd=root,timeout=60)
run('core', [scratch/'FileMonitor.swift',root/'Tests/Regression/CoreHarness.swift'] + [root/'SimPleview'/p for p in ['Utilities/StandardInk.swift','Utilities/AtomicPDFWriter.swift','Utilities/ValidatedLimits.swift','Utilities/SyncTeXLauncher.swift','Models/DocumentIdentity.swift','Managers/ThumbnailStore.swift']])
(scratch/'AIChatViewModel.swift').write_text(source('AppCore/AIChatViewModel.swift').replace('UserDefaults.standard','ReviewDefaults.standard'))
run('ai', [scratch/'AIChatViewModel.swift',root/'Tests/Regression/AIHarness.swift'] + [root/'SimPleview'/p for p in ['AppCore/AIChatService.swift','AppCore/AIChatViewModel+PDF.swift','Utilities/AIContextBuilder.swift','Utilities/AIRequestGate.swift','Utilities/PDFVisionReader.swift','Utilities/StandardInk.swift','Models/AIConfiguration.swift','Managers/ConversationManager.swift']])
subprocess.run(flags + [str(root/'Tests/Regression/RendererHarness.swift'),'-o',str(scratch/'renderer')],check=True,cwd=root)
subprocess.run([str(scratch/'renderer'),str(scratch),str(root/'SimPleview/Resources/ChatRenderer.bundle')],check=True,cwd=root,timeout=40)
for file in ['ReadingTracker.swift','GlobalAuthorManager.swift']:
    (scratch/file).write_text(source('Managers/'+file).replace('UserDefaults.standard','ReviewDefaults.standard'))
run('records', [scratch/'ReadingTracker.swift',scratch/'GlobalAuthorManager.swift',root/'Tests/Regression/RecordsHarness.swift',root/'SimPleview/Models/ReadingRecordModel.swift',root/'SimPleview/Models/DocumentIdentity.swift'])
keysource = source('Utilities/APIKeyStore.swift').replace('UserDefaults.standard','ReviewDefaults.standard')
for call in ['SecItemCopyMatching','SecItemUpdate','SecItemAdd','SecItemDelete']:
    keysource = keysource.replace(call+'(', 'TestVault.'+call+'(')
(scratch/'APIKeyStore.swift').write_text(keysource)
run('keystore', [scratch/'APIKeyStore.swift',root/'Tests/Regression/KeyStoreHarness.swift'])
run('render', [root/'Tests/Regression/RenderHarness.swift'] + [root/'SimPleview'/p for p in ['Managers/ThumbnailManager.swift','Managers/ThumbnailStore.swift','Managers/SearchManager.swift','Models/MemoryPolicy.swift','Utilities/DocumentStatistics.swift','Utilities/StandardInk.swift']])
print('ALL REGRESSIONS PASSED', flush=True)
