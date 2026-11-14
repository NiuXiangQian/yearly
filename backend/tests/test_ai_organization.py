from sqlalchemy import select
from app import organization
from app.config import settings
from app.models import Media, MediaOrganization, MediaSearchIndex, OrganizationReview, MediaFace, User
from test_memory_interviews import memory, interviewer
from test_accounts import act
from test_auto_faces import indexed
from test_faces import image_media, confirm
from conftest import child


def enable(context, **options):
    value = context.client.get('/api/organization/settings').json()
    value.update(tags_enabled=True, **options)
    response = context.client.put('/api/organization/settings', json=value)
    assert response.status_code == 200, response.text


def test_face_exclusion_survives_old_settings_payload_and_validates_profiles(context):
    person = child(context)
    pet = context.client.post('/api/children', json=dict(name='示例宠物', profile_type='pet', species='狗')).json()
    value = context.client.get('/api/organization/settings').json()
    value['face_excluded_child_ids'] = [person['id'], person['id']]
    value['person_rules'][str(person['id'])] = 'automatic'
    saved = context.client.put('/api/organization/settings', json=value)
    assert saved.status_code == 200 and saved.json()['face_excluded_child_ids'] == [person['id']]
    legacy = saved.json(); legacy.pop('face_excluded_child_ids'); legacy['tags_enabled'] = True
    updated = context.client.put('/api/organization/settings', json=legacy)
    assert updated.status_code == 200 and updated.json()['face_excluded_child_ids'] == [person['id']]
    assert updated.json()['tags_enabled'] is True
    for invalid in [[-1], [999999], [pet['id']]]:
        assert context.client.put('/api/organization/settings', json=dict(legacy, face_excluded_child_ids=invalid)).status_code == 422
    assert context.client.get('/api/organization/settings').json()['face_excluded_child_ids'] == [person['id']]
    cleared = context.client.put('/api/organization/settings', json=dict(legacy, face_excluded_child_ids=[]))
    assert cleared.status_code == 200 and cleared.json()['face_excluded_child_ids'] == []


def generate(context, mid):
    with context.db() as db:
        user = db.get(User, 1)
        db.info['actor'] = user
        assert organization.organize_one(db, user)
    return context.client.get('/api/organization/reviews?scope=all').json()['items'][0]


def test_automatic_tags_review_habits_and_durable_revisions(context, monkeypatch):
    def model(db, system, content, schema, **kwargs):
        return schema(tags=[dict(name='公园', source='visual', evidence='公园'),
            dict(name='海边', source='visual', evidence='海边'), dict(name='小宝', source='visual', evidence='公园')])
    monkeypatch.setattr(organization, 'chat', model)
    mid, person = memory(context)
    enable(context)
    entry = generate(context, mid)
    assert entry['status'] == 'automatic' and entry['current']['tags'] == ['公园']
    assert context.client.get(f'/api/media/{mid}').json()['tags'] == ['原有标签', '公园']
    # A later manual tag must survive reviewing or withdrawing only this automatic decision.
    with context.db() as db:
        db.get(Media, mid).tags = ['原有标签', '公园', '后来手动添加']
        db.commit()
    response = context.client.put(f"/api/organization/reviews/{entry['id']}", json=dict(action='correct', remember=True, tag_decisions={'公园':'户外活动'}))
    assert response.status_code == 200, response.text
    value = response.json()
    assert value['status'] == 'corrected' and value['before']['tags'] == ['原有标签']
    assert value['proposed']['tags'] == ['公园'] and value['current']['tags'] == ['户外活动']
    assert value['media']['tags'] == ['原有标签', '后来手动添加', '户外活动']
    assert len(value['events']) == 2 and value['events'][-1]['value']['remember']
    rules = context.client.get('/api/organization/settings').json()['tag_rules']
    assert rules['公园'] == {'target':'户外活动','mode':'automatic'}
    # New media follows the canonical name and skips the pending queue, but keeps the full ledger.
    other, _ = memory(context)
    automatic = generate(context, other)
    assert automatic['status'] == 'automatic' and automatic['current']['tags'] == ['户外活动']
    assert context.client.get('/api/organization/reviews').json()['pending'] == 0
    withdraw = context.client.put(f"/api/organization/reviews/{entry['id']}", json=dict(action='reject', remember=True))
    assert withdraw.status_code == 200 and withdraw.json()['media']['tags'] == ['原有标签', '后来手动添加']
    assert len(withdraw.json()['events']) == 3
    assert context.client.get('/api/organization/settings').json()['tag_rules']['公园']['mode'] == 'skip'
    existing = context.client.put(f"/api/organization/reviews/{automatic['id']}", json=dict(action='correct',tag_decisions={'户外活动':'原有标签'}))
    assert existing.status_code == 200
    assert context.client.put(f"/api/organization/reviews/{automatic['id']}",json=dict(action='reject')).json()['media']['tags'] == ['原有标签']

    with context.db() as db:
        assert not organization.organize_one(db, db.get(User, 1)), 'unchanged sources are not charged or tagged again'


def test_person_matching_has_review_history_and_remembered_manual_override(context, monkeypatch):
    monkeypatch.setattr(settings(), 'face_auto_link_enabled', True)
    person = child(context, '参考人物')
    source = image_media(context); seed = indexed(context, source, [1, 0])
    target = image_media(context); fid = indexed(context, target, [1, 0])
    assert confirm(context, source, seed, person['id']).json()['auto_linked'] == 1
    queue = context.client.get('/api/organization/reviews?kind=face').json()
    assert queue['pending'] == 1
    entry = queue['items'][0]
    assert entry['media']['id'] == target and entry['evidence']['reference_face_id'] == seed
    response = context.client.put(f"/api/organization/reviews/{entry['id']}", json=dict(action='reject', remember=True))
    assert response.status_code == 200, response.text
    assert response.json()['status'] == 'rejected' and response.json()['current']['child_id'] is None
    with context.db() as db:
        assert db.get(MediaFace, fid).auto_link_blocked
    other = image_media(context); indexed(context, other, [1, 0])
    assert context.client.post('/api/faces/auto-link').json()['linked_faces'] == 0
    assert context.client.get('/api/organization/settings').json()['person_rules'][str(person['id'])] == 'manual'
    # Correcting an old ledger after a later face edit cannot silently overwrite that edit.
    assert confirm(context, target, fid, person['id']).status_code == 200
    assert context.client.put(f"/api/organization/reviews/{entry['id']}", json=dict(action='approve')).status_code == 409


def test_failures_retry_access_and_preference_audit(context, monkeypatch):
    from fastapi import HTTPException
    mid, _ = memory(context); enable(context)
    monkeypatch.setattr(organization, 'chat', lambda *a, **k: (_ for _ in ()).throw(HTTPException(502, '模拟服务失败')))
    with context.db() as db:
        user = db.get(User, 1); db.info['actor'] = user
        assert organization.organize_one(db, user)
        assert db.get(MediaOrganization, mid).status == 'failed'
        assert not organization.organize_one(db, user)
    assert context.client.get('/api/organization/reviews').json()['errors'][0]['message'] == '模拟服务失败'
    for role in ['member', 'viewer']:
        act(context, role)
        for method, path, body in [('GET','/api/organization/reviews',None),('GET','/api/organization/settings',None),('PUT','/api/organization/reviews/1',{'action':'approve'}),('POST','/api/organization/run',{})]:
            assert context.client.request(method,path,json=body).status_code == 403


def test_pet_habit_automatically_matches_without_creating_reference_feedback(context, monkeypatch):
    from app import pets
    from app.models import MediaPetIndex
    pet = context.client.post('/api/children', json=dict(name='示例狗狗', profile_type='pet', species='狗')).json()
    source, target = image_media(context), image_media(context)
    detection = dict(box=[0,0,1,1], frame_seconds=None, appearance='棕白色竖耳小狗', embedding=[1,0], thumbnail='', child_id=None, ignored=False, confirmed_by=None)
    with context.db() as db:
        db.add_all([MediaPetIndex(media_id=mid, model=pets.MODEL, source_sha256='a'*64, detections=[dict(detection)]) for mid in [source,target]])
        db.commit()
    assert context.client.put(f'/api/pets/media/{source}/confirm', json=dict(index=0, child_id=pet['id'])).status_code == 200
    with context.db() as db:
        assert db.get(MediaPetIndex,target).detections[0]['child_id'] is None
    entry = context.client.get('/api/organization/reviews?scope=all&kind=pet').json()['items'][0]
    response = context.client.put(f"/api/organization/reviews/{entry['id']}",json=dict(action='approve',remember=True))
    assert response.status_code == 200, response.text
    with context.db() as db:
        dog = db.get(MediaPetIndex,target).detections[0]
        assert dog['child_id'] == pet['id'] and dog['confirmed_by'] is None and dog['auto_assigned']
    records = context.client.get('/api/organization/reviews?scope=all&kind=pet').json()['items']
    assert any(r['status']=='automatic' and r['media']['id']==target and r['evidence']['reference_media_id']==source for r in records)
    assert context.client.delete(f'/api/pets/media/{target}').status_code == 200
    assert context.client.get('/api/organization/reviews?kind=pet').json()['pending'] == 0


def test_interview_additions_also_auto_apply_tags_with_reviewable_evidence(context, interviewer):
    mid, _ = memory(context); enable(context)
    response = context.client.post(f'/api/memory-interviews/{mid}/prepare',json={})
    assert response.status_code == 200, response.text
    assert not response.json()['outdated']
    assert context.client.get(f'/api/media/{mid}').json()['tags'] == ['原有标签','公园']
    assert context.client.get('/api/organization/reviews?kind=tags').json()['pending'] == 0
    entry = context.client.get('/api/organization/reviews?kind=tags&scope=all').json()['items'][0]
    assert entry['evidence']['tags'][0]['source'] == 'visual' and entry['current']['tags'] == ['公园']


def test_background_resumes_interrupted_processing_and_batch_retry_is_idempotent(context, monkeypatch):
    mid, _ = memory(context); enable(context)
    with context.db() as db:
        db.add(MediaOrganization(media_id=mid,source_updated_at=db.get(MediaSearchIndex,mid).updated_at,status='pending'))
        db.commit()
    calls=[]
    def model(db, system, content, schema, **kwargs):
        calls.append(content);return schema(tags=[dict(name='公园',source='visual',evidence='公园')])
    monkeypatch.setattr(organization,'chat',model)
    result=context.client.post('/api/organization/run?limit=3')
    assert result.status_code==200 and result.json()['processed']==1
    assert context.client.post('/api/organization/run?limit=3').json()['processed']==0
    assert len(calls)==1


def test_reviewing_a_face_also_returns_additional_automatic_match_counts(context, monkeypatch):
    import math
    monkeypatch.setattr(settings(), 'face_auto_link_enabled', True)
    person=child(context,'参考人物')
    seed_media=image_media(context); indexed(context,seed_media,[1,0],person['id'])
    target=image_media(context); fid=indexed(context,target,[.9,math.sqrt(.19)])
    chained=image_media(context); chained_id=indexed(context,chained,[.6,.8])
    assert context.client.post('/api/faces/auto-link').json()['linked_faces']==1
    row=context.client.get('/api/organization/reviews?kind=face').json()['items'][0]
    result=context.client.put(f"/api/organization/reviews/{row['id']}",json=dict(action='approve'))
    assert result.status_code==200, result.text
    assert result.json()['auto_linked']==1 and result.json()['auto_reset']==0
    with context.db() as db:
        assert db.get(MediaFace,chained_id).child_id==person['id'] and db.get(MediaFace,chained_id).confirmed_by is None


def test_automatic_tags_never_queue_even_at_capacity_and_manual_rules_rejected(context):
    mid, _ = memory(context)
    enable(context, tag_rules={'不要': {'target': '', 'mode': 'skip'}})
    with context.db() as db:
        media = db.get(Media, mid)
        media.tags = [f'已有{i}' for i in range(29)]
        organization.apply_automatic_tags(db, media, [
            dict(name=name, source='visual', evidence=name) for name in ['公园', '散步', '不要']
        ], '公园散步', 'test')
        db.commit()
    result = context.client.get('/api/organization/reviews?kind=tags').json()
    assert result['pending'] == 0 and result['items'] == []
    row = context.client.get('/api/organization/reviews?kind=tags&scope=all').json()['items'][0]
    assert row['status'] == 'automatic' and row['current'] == {'tags': ['公园'], 'decisions': {'公园': '公园', '散步': None}}
    assert len(row['media']['tags']) == 30
    options = context.client.get('/api/organization/settings').json()
    options['tag_rules'] = {'公园': {'target': '公园', 'mode': 'manual'}}
    assert context.client.put('/api/organization/settings', json=options).status_code == 422


def test_tag_queue_migration_preserves_edits_skips_and_identity_reviews(context):
    import importlib.util
    from pathlib import Path
    from app.models import OrganizationSettings
    path = Path(__file__).parents[1] / 'alembic/versions/0026_automatic_tags.py'
    spec = importlib.util.spec_from_file_location('automatic_tags_migration', path)
    migration = importlib.util.module_from_spec(spec); spec.loader.exec_module(migration)
    mid, _ = memory(context)
    enable(context)
    with context.db() as db:
        db.get(Media, mid).tags = ['原有标签', '手动新增']
        db.get(OrganizationSettings, 1).options = dict(tags_enabled=True, people_enabled=True,
            tag_rules={'待添加': {'target': '待添加', 'mode': 'manual'}, '忽略': {'target': '', 'mode': 'skip'}}, person_rules={})
        row = OrganizationReview(media_id=mid, kind='tags', target_id=str(mid), automatic=True, status='pending',
            before_value={'tags': ['原有标签']}, proposed_value={'tags': ['手动已移除', '待添加', '忽略']},
            current_value={'tags': ['手动已移除']}, evidence={'tags': [{'name': '待添加', 'source_name': '待添加', 'rule': 'manual'}]}, events=[])
        person = OrganizationReview(media_id=mid, kind='face', target_id='1', automatic=True, status='pending',
            before_value={}, proposed_value={}, current_value={}, evidence={}, events=[])
        db.add_all([row, person]); db.flush()
        assert migration.confirm_pending_tags(db.connection()) == 1
        db.expire_all()
        assert db.get(Media, mid).tags == ['原有标签', '手动新增', '待添加']
        assert row.status == 'automatic' and row.current_value['tags'] == ['待添加']
        assert row.events[-1]['action'] == 'automatic'
        assert person.status == 'pending'
        assert db.get(OrganizationSettings, 1).options['tag_rules']['待添加']['mode'] == 'automatic'
        assert migration.confirm_pending_tags(db.connection()) == 0
        assert len(row.events) == 1
