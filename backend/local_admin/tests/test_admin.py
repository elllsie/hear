import json
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

import httpx

from backend.local_admin.server import Application, Handler
from backend.local_admin.operations import Queue, audio_row, remote_get
from backend.local_admin.store import Store, component, now, write_json


class AdminTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.app = Application(self.temp.name, worker=False)

    def tearDown(self):
        self.temp.cleanup()

    def import_book(self):
        return self.app.post('/api/books/import', {'id':'Test_Book','title':'测试词书','language':'english','words':[{'id':'1','text':'abroad','meaningZh':'adv. 在国外','meaningEn':'adv. in another country'}]})

    def test_password_and_one_time_bootstrap(self):
        token = self.app.bootstrap
        sid, session = self.app.login(token=token)
        self.assertTrue(session['csrf'])
        self.assertIn(sid, self.app.sessions)
        with self.assertRaises(ValueError):
            self.app.login(token=token)
        self.app.login(password=self.app.initial_password)
        with self.assertRaises(ValueError):
            self.app.login(password='incorrect')
        self.assertNotIn(self.app.initial_password, (Path(self.temp.name)/'credentials.json').read_text())

    def test_login_rate_limit(self):
        for _ in range(8):
            with self.assertRaises(ValueError):
                self.app.login(password='wrong')
        with self.assertRaisesRegex(ValueError, '尝试次数'):
            self.app.login(password=self.app.initial_password)

    def test_path_traversal_and_duplicate_ids(self):
        for key in ('../bad','/tmp/bad','a.b','a;b','', 'a'*81):
            with self.assertRaises(ValueError):
                component(key)
        with self.assertRaises(ValueError):
            Store.validate_words([{'id':1,'text':'a'},{'id':'1','text':'b'}])
        with self.assertRaises(ValueError):
            Store.validate_words([{'id':'1','text':'a','meaningZh':[]}])

    def test_import_preview_is_read_only(self):
        result = self.app.post('/api/books/import-preview', {'words':[{'id':'one','text':'dare'}]})
        self.assertEqual(result['count'],1)
        self.assertEqual(self.app.store.query('SELECT * FROM books'),[])
        self.assertFalse((Path(self.temp.name)/'books').exists())

    def test_import_and_optimistic_edit(self):
        self.import_book()
        self.assertEqual(self.app.store.words('Test_Book')[0]['text'],'abroad')
        original = self.app.store.word('Test_Book','1')
        self.app.post('/api/word/save',{'book':'Test_Book','id':'1','expected':original,'changes':{'text':'dark'}})
        self.assertEqual(self.app.store.word('Test_Book','1')['text'],'dark')
        with self.assertRaisesRegex(ValueError,'其他页面'):
            self.app.post('/api/word/save',{'book':'Test_Book','id':'1','expected':original,'changes':{'text':'dare'}})
        with self.assertRaises(ValueError):
            self.import_book()

    def test_audio_manifest_and_deduplicated_queue(self):
        self.import_book()
        payload={'book':'Test_Book','ids':['1'],'provider':'kokoro','speed':.85,'audio_kind':'word'}
        first=self.app.post('/api/audio/generate',payload)['job_id']
        second=self.app.post('/api/audio/generate',payload)['job_id']
        self.assertEqual(first,second)
        job=self.app.store.job(first)
        self.assertEqual(job['payload']['rows'][0]['target_path'],'v2/words/en-US/Test_Book/abroad_1.mp3')
        self.assertFalse((Path(self.temp.name)/'jobs'/first/'audio').exists())
        with self.assertRaises(ValueError):
            self.app.post('/api/audio/generate',{**payload,'provider':'shell'})
        with self.assertRaises(ValueError):
            self.app.post('/api/audio/generate',{**payload,'speed':float('nan')})
        with self.assertRaises(ValueError):
            self.app.post('/api/audio/generate',{**payload,'audio_kind':'meaningZh'})

    def test_flags_persist_and_cancel_queue(self):
        self.import_book()
        self.app.post('/api/flags',{'book':'Test_Book','id':'1','note':'尾音奇怪'})
        self.assertEqual(self.app.get('/api/flags',{})['items'][0]['text'],'abroad')
        other = Store(self.temp.name)
        self.assertEqual(other.query('SELECT count(*) n FROM flags')[0]['n'],1)
        job=self.app.post('/api/audio/audit',{'book':'Test_Book','ids':['1']})['job_id']
        self.app.post('/api/job/cancel',{'id':job})
        self.assertEqual(self.app.store.job(job)['status'],'cancelled')
        retry=self.app.post('/api/job/retry',{'id':job})['job_id']
        self.assertNotEqual(job,retry)

    def test_restart_marks_only_running_interrupted(self):
        job=self.app.queue.enqueue('article_ai','a',{})
        self.app.store.execute("UPDATE jobs SET status='running' WHERE id=?",(job,))
        queued=self.app.queue.enqueue('article_ai','b',{'different':1})
        store=Store(self.temp.name)
        self.assertEqual(store.job(job)['status'],'interrupted')
        self.assertEqual(store.job(queued)['status'],'queued')

    def test_publication_requires_confirmation_and_success(self):
        self.import_book()
        source=self.app.post('/api/audio/generate',{'book':'Test_Book','ids':['1']})['job_id']
        with self.assertRaises(ValueError):
            self.app.post('/api/audio/publish',{'job_id':source})
        with self.assertRaises(ValueError):
            self.app.post('/api/audio/publish',{'job_id':source,'confirm':True})
        row=audio_row(self.app.store,'Test_Book','1')
        self.app.store.execute("UPDATE jobs SET status='succeeded',result=? WHERE id=?",(json.dumps({'items':[{**row,'bytes':1000}]}),source))
        with self.assertRaises(ValueError):
            self.app.post('/api/audio/publish',{'job_id':source,'indexes':[999],'confirm':True})
        pub=self.app.post('/api/audio/publish',{'job_id':source,'confirm':True})['job_id']
        self.assertEqual(self.app.store.job(pub)['kind'],'audio_publish')

    def test_publication_backup_before_upload_and_verify(self):
        self.import_book()
        source=self.app.post('/api/audio/generate',{'book':'Test_Book','ids':['1']})['job_id']
        row=audio_row(self.app.store,'Test_Book','1')
        artifact=Path(self.temp.name)/'jobs'/source/'audio'/row['target_path']
        artifact.parent.mkdir(parents=True)
        artifact.write_bytes(b'new'*400)
        self.app.store.execute("UPDATE jobs SET status='succeeded',result=? WHERE id=?",(json.dumps({'items':[{**row,'bytes':1200}]}),source))
        pub=self.app.post('/api/audio/publish',{'job_id':source,'confirm':True})['job_id']
        old=b'old'*400
        def upload(*args,**kwargs):
            backup=Path(self.temp.name)/'jobs'/pub/'backup/v2/words/en-us/test_book/abroad_1.mp3'
            self.assertEqual(backup.read_bytes(),old)
            self.assertEqual(kwargs['content'],artifact.read_bytes())
            return httpx.Response(200,request=httpx.Request('POST',args[0]))
        with tempfile.TemporaryDirectory() as generated, patch('backend.local_admin.operations.credentials',return_value=('https://example.invalid',{})), patch('backend.local_admin.operations.remote_get',side_effect=[old,artifact.read_bytes()]), patch('backend.local_admin.operations.httpx.post',side_effect=upload), patch('backend.local_admin.operations.GENERATED',Path(generated)):
            result=self.app.queue.dispatch(self.app.store.job(pub))
            self.assertIn('逐条校验',result['message'])
            self.assertEqual((Path(generated)/row['target_path']).read_bytes(),artifact.read_bytes())
        self.assertEqual(self.app.store.job(pub)['payload']['rows'],[row])

    def test_rollback_refuses_newer_online_audio(self):
        self.import_book()
        row=audio_row(self.app.store,'Test_Book','1')
        generation=self.app.queue.enqueue('audio_generate','generate',{'rows':[row]})
        generated=Path(self.temp.name)/'jobs'/generation/'audio'/row['target_path']
        generated.parent.mkdir(parents=True)
        generated.write_bytes(b'released')
        publication=self.app.queue.enqueue('audio_publish','publish',{'source_job':generation,'rows':[row]})
        backup=Path(self.temp.name)/'jobs'/publication/'backup/v2/words/en-us/test_book/abroad_1.mp3'
        backup.parent.mkdir(parents=True)
        backup.write_bytes(b'old')
        rollback=self.app.queue.enqueue('audio_rollback','rollback',{'source_job':publication,'rollback_rows':[row]})
        with patch('backend.local_admin.operations.remote_get',return_value=b'newer'):
            with self.assertRaisesRegex(ValueError,'线上音频已变化'):
                self.app.queue.dispatch(self.app.store.job(rollback))

    def test_missing_storage_object_400_is_not_a_credentials_error(self):
        response=httpx.Response(400,json={'statusCode':'404','message':'Object not found'},request=httpx.Request('GET','https://example.invalid'))
        with patch('backend.local_admin.operations.remote_audio',return_value='https://example.invalid'),patch('backend.local_admin.operations.httpx.get',return_value=response):
            self.assertIsNone(remote_get({}))
        response=httpx.Response(400,json={'message':'Invalid credentials'},request=httpx.Request('GET','https://example.invalid'))
        with patch('backend.local_admin.operations.remote_audio',return_value='https://example.invalid'),patch('backend.local_admin.operations.httpx.get',return_value=response):
            with self.assertRaises(httpx.HTTPStatusError):
                remote_get({})

    def test_zero_exit_script_with_failed_items_is_not_success(self):
        from unittest.mock import MagicMock
        process=MagicMock()
        process.stdout=iter(['FAILED: one episode\n','Validation rejected 1 episode(s).\n'])
        process.wait.return_value=0
        context=MagicMock()
        context.__enter__.return_value=process
        with patch('backend.local_admin.operations.subprocess.Popen',return_value=context):
            with self.assertRaisesRegex(RuntimeError,'1 项失败'):
                self.app.queue.run('sample','validate_podcast_episodes.py',[])

    def test_article_ai_saves_only_to_local_draft(self):
        article=self.app.post('/api/articles/save',{'title':'Article','text':'Learning is a useful and rewarding daily practice.'})['id']
        payload=self.app.get('/api/article',{'id':article})
        job=self.app.queue.enqueue('article_ai','AI',{'article':payload})
        insight={'summary_zh':'学习总结','summary_en':'A learning summary','key_points':['每天练习'],'difficult_words':[{'word':'rewarding','meaning_zh':'有益的','meaning_en':'satisfying'}]}
        with patch('generate_podcast_ai_insights.call_ai',return_value=(insight,'test-model')):
            result=self.app.queue.dispatch(self.app.store.job(job))
        self.assertEqual(result['insight']['model'],'test-model')
        self.assertEqual(self.app.get('/api/article',{'id':article})['result']['summary_zh'],'学习总结')

    def test_podcast_actions_are_allowlisted(self):
        source=self.app.store.sources()[0]
        with self.assertRaises(ValueError):
            self.app.post('/api/podcast/run',{'source':source['key'],'action':'sync','limit':1})
        for action in ('rm -rf /','publish','--force'):
            with self.assertRaises(ValueError):
                self.app.post('/api/podcast/run',{'source':source['key'],'action':action,'confirm':True})
        job=self.app.post('/api/podcast/run',{'source':source['key'],'action':'preview','limit':1})['job_id']
        with patch.object(self.app.queue,'run') as runner:
            self.app.queue.dispatch(self.app.store.job(job))
            args=runner.call_args.args
            self.assertEqual(args[1],'sync_podcasts.py')
            self.assertIn('--dry-run',args[2])

    def test_article_result_edit_does_not_publish(self):
        article=self.app.post('/api/articles/save',{'title':'Article','text':'A useful text about learning languages.'})['id']
        result={'summary_zh':'总结','summary_en':'Summary','key_points':['要点'],'difficult_words':[{'word':'useful','meaning_zh':'有用的','meaning_en':'helpful'}]}
        self.app.post('/api/articles/result',{'id':article,'expected':None,'result':result})
        self.assertEqual(self.app.get('/api/article',{'id':article})['result'],result)
        self.assertEqual(self.app.store.query('SELECT * FROM jobs'),[])
        with self.assertRaises(ValueError):
            self.app.post('/api/articles/result',{'id':article,'expected':None,'result':result})
        self.app.post('/api/articles/save',{'id':article,'title':'Article','text':'A changed text about learning languages.'})
        self.assertIsNone(self.app.get('/api/article',{'id':article})['result'])


class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory()
        cls.app=Application(cls.temp.name,worker=False)
        cls.server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        cls.server.app=cls.app
        cls.address=f'http://127.0.0.1:{cls.server.server_port}'
        cls.thread=threading.Thread(target=cls.server.serve_forever,daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.temp.cleanup()

    def test_http_auth_host_origin_csrf_and_logout(self):
        with httpx.Client(base_url=self.address,timeout=10) as client:
            self.assertEqual(client.get('/').status_code,200)
            self.assertEqual(client.get('/api/books').status_code,401)
            self.assertEqual(client.get('/api/books',headers={'Host':'evil.test'}).status_code,403)
            data={'password':self.app.initial_password}
            self.assertEqual(client.post('/api/login',json=data,headers={'Origin':'https://evil.test'}).status_code,403)
            response=client.post('/api/login',json=data,headers={'Origin':self.address})
            self.assertEqual(response.status_code,200)
            self.assertIn('HttpOnly',response.headers['set-cookie'])
            csrf=response.json()['csrf']
            self.assertEqual(client.get('/api/books').status_code,200)
            self.assertEqual(client.post('/api/logout',json={},headers={'Origin':self.address}).status_code,403)
            self.assertEqual(client.post('/api/logout',json={},headers={'Origin':self.address,'X-CSRF-Token':csrf}).status_code,200)
            self.assertEqual(client.get('/api/books').status_code,401)

    def test_loopback_audio_range_and_no_arbitrary_files(self):
        with httpx.Client(base_url=self.address,headers={'Origin':self.address},timeout=10) as client:
            response=client.post('/api/login',json={'password':self.app.initial_password})
            self.assertEqual(response.status_code,200)
            # Known bundled local audio; no remote operations.
            response=client.get('/api/audio?book=KaoYan_2&id=1171',headers={'Range':'bytes=0-99'})
            self.assertEqual(response.status_code,206)
            self.assertEqual(len(response.content),100)
            self.assertTrue(response.headers['content-range'].startswith('bytes 0-99/'))
            self.assertEqual(client.get('/api/audio?book=../../backend/.env&id=1').status_code,400)
            self.assertNotEqual(client.get('/backend/.env').status_code,200)


if __name__=='__main__':
    unittest.main()
