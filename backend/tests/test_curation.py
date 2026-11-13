from datetime import datetime, timedelta
from types import SimpleNamespace as NS

from sqlalchemy import select

from app import curation
from app.models import Media, MediaChild, MediaCuration, MediaFile
from conftest import child, upload
from test_accounts import act
from test_faces import image_media


def test_grouping_uses_complete_assets_and_bounded_capture_times():
    def media(mid, sha, seconds=0, kind="photo", live=""):
        files = [NS(file_role="original", sha256=sha, file_size=100, upload_status="complete")]
        if live: files.append(NS(file_role="live_video", sha256=live, file_size=200, upload_status="complete"))
        return NS(id=mid, media_type=kind, files=files, taken_at_local=datetime(2026,1,1)+timedelta(seconds=seconds),
                  created_at=datetime(2026,1,1), owner_id=1, folder_id=None, device_make="test", device_model="camera")
    groups = curation.group_media([media(1,"a"),media(2,"a"),media(3,"b",10),media(4,"c",11),media(5,"d",13),
                                   media(6,"same",20,"live_photo","motion1"),media(7,"same",30,"live_photo","motion2")])
    assert next(g for g in groups if g["kind"]=="duplicate")["media"][0].id==2
    capture=next(g for g in groups if g["kind"]=="capture")
    assert {m.id for m in capture["media"]} == {3,4}
    assert not any({6,7}.issubset({m.id for m in g["media"]}) for g in groups)


def test_existing_bindings_not_tasks_and_manual_batch_is_atomic_reversible(context, monkeypatch):
    from app import faces
    monkeypatch.setattr(faces,"auto_link",lambda *args: (_ for _ in ()).throw(AssertionError("identity inference must not run")))
    person=child(context,"合成档案")
    bound=upload(context,[person["id"]])["media_id"]
    one=upload(context)["media_id"];two=upload(context)["media_id"]
    data=context.client.get('/api/curation/groups').json()
    assert data['unfiled_media']==2
    assert bound not in {i['media']['id'] for g in data['items'] for i in g['items']}
    response=context.client.post('/api/curation/batch',json=dict(media_ids=[one,two],child_ids=[person['id']],action='add'))
    assert response.status_code==200,response.text
    assert response.json()['count']==2
    assert context.client.get('/api/curation/groups').json()['unfiled_media']==0
    token=response.json()['undo_token']
    assert context.client.post('/api/curation/undo/'+token).status_code==200
    assert context.client.post('/api/curation/undo/'+token).status_code==200
    assert context.client.get('/api/curation/groups').json()['unfiled_media']==2
    with context.db() as db:
        assert list(db.scalars(select(MediaChild.child_id).where(MediaChild.media_id==bound)))==[person['id']]
    bad=context.client.post('/api/curation/batch',json=dict(media_ids=[one,999999],action='ignore'))
    assert bad.status_code==404
    assert context.client.get('/api/curation/groups').json()['unfiled_media']==2


def test_undo_rejects_followup_changes_and_old_client_still_reads(context):
    one=upload(context)["media_id"]
    token=context.client.post('/api/curation/batch',json=dict(media_ids=[one],action='ignore')).json()['undo_token']
    context.client.post('/api/curation/batch',json=dict(media_ids=[one],action='done'))
    assert context.client.post('/api/curation/undo/'+token).status_code==409
    assert context.client.get(f'/api/media/{one}').status_code==200
    assert context.client.get('/api/curation/groups?scope=handled').json()['group_count']==1
    act(context,'viewer')
    assert context.client.get('/api/curation/groups').status_code==403
    assert context.client.post('/api/curation/undo/'+token).status_code==403


def test_quality_reuses_cached_result_without_identity_or_media_mutations(context, monkeypatch):
    mid=image_media(context)
    # No decoding or provider call on a matching cache entry.
    with context.db() as db:
        file=db.scalar(select(MediaFile).where(MediaFile.media_id==mid))
        import hashlib,json
        fingerprint=hashlib.sha256(json.dumps([file.sha256,db.get(Media,mid).media_type,curation.settings().ai_analysis_model,curation.QUALITY_VERSION]).encode()).hexdigest()
        answer=dict(frames=[dict(frame=0,clarity=4,blurred=False,face_visibility='none',reason='合成测试')],representative=0,seconds=[None],thumbnail='data:image/jpeg;base64,test')
        db.add(MediaCuration(media_id=mid,fingerprint=fingerprint,quality=answer,disposition='ignored'));db.commit()
    monkeypatch.setattr(curation,'chat',lambda *args,**kwargs: (_ for _ in ()).throw(AssertionError('cached quality must not incur calls')))
    response=context.client.post(f'/api/curation/media/{mid}/quality')
    assert response.status_code==200,response.text
    assert response.json()==answer
    with context.db() as db:
        assert db.get(MediaCuration,mid).disposition=='ignored'
        assert list(db.scalars(select(MediaChild).where(MediaChild.media_id==mid)))==[]


def test_quality_validates_provider_frames_and_caches_success(context, monkeypatch):
    import io
    from PIL import Image
    mid=image_media(context);calls=[]
    stream=io.BytesIO();Image.new('RGB',(100,100),'blue').save(stream,'JPEG')
    monkeypatch.setattr(curation,'sampled_images',lambda *args:[(None,stream.getvalue())])
    def chat(*args,**kwargs):
        calls.append(kwargs)
        return curation.QualityAnswer(frames=[curation.FrameQuality(frame=0,clarity=4,blurred=False,face_visibility='none',reason='画面清楚')],representative=1 if len(calls)==1 else 0)
    monkeypatch.setattr(curation,'chat',chat)
    assert context.client.post(f'/api/curation/media/{mid}/quality').status_code==502
    response=context.client.post(f'/api/curation/media/{mid}/quality')
    assert response.status_code==200,response.text
    assert response.json()['frames'][0]['reason']=='画面清楚'
    assert context.client.post(f'/api/curation/media/{mid}/quality').status_code==200
    assert len(calls)==2


def test_video_sampling_uses_preview_duration_and_does_not_create_face_records(context, tmp_path):
    import shutil,subprocess,imageio_ffmpeg
    from app.models import VideoPreview,MediaFace
    mid=upload(context)['media_id'];video=tmp_path/'sample.mp4'
    subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(),'-hide_banner','-loglevel','error','-f','lavfi','-i','color=c=blue:s=160x120:d=2',str(video)],check=True,capture_output=True)
    with context.db() as db:
        media=db.get(Media,mid);media.media_type='video';media.duration_ms=999999
        file=db.scalar(select(MediaFile).where(MediaFile.media_id==mid))
        db.add(VideoPreview(sha256=file.sha256,status='ready',object_key='synthetic-video'));db.flush()
        class Bucket:
            def get_object_to_file(self,key,target): shutil.copyfile(video,target)
        samples=curation.sampled_images(db,NS(bucket=Bucket()),media,file)
        assert len(samples)==5 and all(raw for _,raw in samples)
        assert 1.8 <= samples[-1][0] <= 2.0
        assert list(db.scalars(select(MediaFace).where(MediaFace.media_id==mid)))==[]


def test_all_groups_with_real_media_capture_metadata(context):
    mids=[upload(context)['media_id'] for _ in range(3)]
    with context.db() as db:
        for i,mid in enumerate(mids):
            media=db.get(Media,mid);media.device_model='synthetic-camera';media.device_make='test'
            media.taken_at_local=datetime(2026,1,1)+timedelta(seconds=[0,1,3][i])
            db.scalar(select(MediaFile).where(MediaFile.media_id==mid)).sha256=str(i+1)*64
        db.commit()
    response=context.client.get('/api/curation/groups?scope=all&limit=48')
    assert response.status_code==200,response.text
    data=response.json();assert data['group_count']==2
    capture=next(g for g in data['items'] if g['kind']=='capture')
    assert {i['media']['id'] for i in capture['items']}==set(mids[:2])
