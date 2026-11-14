import json
from fastapi import HTTPException
from app import ai_search as ai
from app.models import Media, MediaSearchIndex, Child
from test_ai_search import provider, add_index, vector
from test_faces import confirm, image_media
from test_auto_faces import indexed
from conftest import upload


def mother(context):
    response = context.client.post('/api/children',json=dict(name='林女士',profile_type='person',relationship='妈妈'))
    assert response.status_code==200
    return response.json()['id']


def test_mother_birthday_uses_live_tags_and_confirmed_identity_and_respects_corrections(context,provider,monkeypatch):
    mom=mother(context)
    dad=context.client.post('/api/children',json=dict(name='陈先生',profile_type='person',relationship='爸爸')).json()['id']
    birthday=image_media(context);fid=indexed(context,birthday,[1,0])
    street=upload(context,[mom])['media_id']
    other=upload(context,[dad])['media_id']
    unknown=upload(context)['media_id']
    for mid in [birthday,street,other,unknown]:add_index(context,mid,'室内合照',vector(-1) if mid==birthday else vector())
    for mid in [birthday,other,unknown]:context.client.put(f'/api/media/{mid}',json={'tags':['生日']})
    def plan(db,system,content,schema=None):
        payload=json.loads(content)
        assert '生日' in payload['tag_library']
        return schema(scene='生日庆祝、生日蛋糕、蜡烛',evidence_groups=[['生日','蛋糕']],depicted=False,start=None,end=None,profile_ids=[mom],profile_mentions=['妈妈'],media_type=None)
    monkeypatch.setattr(ai,'chat',plan)
    search=lambda: context.client.post('/api/ai-search',json={'query':'妈妈过生日'})
    assert [m['id'] for m in search().json()['items']]==[], 'unconfirmed identity must not be guessed'
    assert confirm(context,birthday,fid,mom).status_code==200
    with context.db() as db:
        target=db.get(Media,birthday);row=db.get(MediaSearchIndex,birthday)
        _,fp=ai.search_context(target,row)
        row.context_fingerprint,row.context_embedding=fp,vector();db.commit()
    result=search();assert result.status_code==200,result.text
    assert [m['id'] for m in result.json()['items']]==[birthday]
    # Removing a label immediately invalidates the old semantic context; do not wait for the worker.
    context.client.put(f'/api/media/{birthday}',json={'tags':[],'child_ids':[mom]})
    assert [m['id'] for m in search().json()['items']]==[]
    context.client.put(f'/api/media/{birthday}',json={'tags':['生日'],'child_ids':[mom]})
    assert [m['id'] for m in search().json()['items']]==[birthday]
    assert confirm(context,birthday,fid,dad).status_code==200
    assert [m['id'] for m in search().json()['items']]==[]


def test_context_cache_miss_hit_empty_and_metadata_changes_without_visual_reanalysis(context,provider):
    with context.db() as db:assert not ai.index_context_one(db)
    mid=upload(context)['media_id'];add_index(context,mid,'室内合照')
    with context.db() as db:
        original=db.get(MediaSearchIndex,mid).updated_at
        assert ai.index_context_one(db)
        assert not ai.index_context_one(db)
        assert db.get(MediaSearchIndex,mid).updated_at==original
    assert provider==[], 'a context with no curated metadata reuses the existing visual vector'
    mom=mother(context)
    context.client.put(f'/api/media/{mid}',json={'tags':['生日'],'child_ids':[mom]})
    with context.db() as db:
        assert ai.index_context_one(db)
        assert not ai.index_context_one(db)
        row=db.get(MediaSearchIndex,mid);old=row.context_fingerprint
        assert row.updated_at==original, 'context cache refresh must not retrigger visual tag generation'
    assert len(provider)==1 and provider[0][0]=='embeddings'
    assert '生日' in provider[0][1]['input'] and '妈妈' in provider[0][1]['input'] and '林女士' in provider[0][1]['input']
    context.client.put(f'/api/children/{mom}',json=dict(name='林女士',profile_type='person',relationship='妈妈',nickname='老妈'))
    with context.db() as db:
        assert ai.index_context_one(db)
        assert db.get(MediaSearchIndex,mid).context_fingerprint!=old
    assert len(provider)==2 and '老妈' in provider[-1][1]['input']


def test_context_failure_keeps_visual_index_and_does_not_rebill_until_retry(context,provider,monkeypatch):
    mid=upload(context)['media_id'];add_index(context,mid,'海边')
    context.client.put(f'/api/media/{mid}',json={'tags':['海边']})
    def fail(*args):raise HTTPException(502,'模拟向量服务失败')
    monkeypatch.setattr(ai,'embed',fail)
    with context.db() as db:
        original=db.get(MediaSearchIndex,mid).updated_at
        assert ai.index_context_one(db)
        row=db.get(MediaSearchIndex,mid)
        assert row.status=='ready' and row.embedding==vector() and row.context_embedding is None and row.updated_at==original
        assert not ai.index_context_one(db)
    assert provider==[]


def test_current_scope_excludes_hidden_tags_and_profiles_from_search_context(context,provider):
    from test_accounts import act
    visible=upload(context)['media_id'];hidden=upload(context)['media_id']
    for mid in [visible,hidden]:add_index(context,mid,'海边')
    context.client.put(f'/api/media/{hidden}',json={'tags':['不应发送的私人标签'],'share_allowed':False})
    act(context,'viewer')
    response=context.client.post('/api/ai-search',json={'query':'海边'})
    assert response.status_code==200 and [m['id'] for m in response.json()['items']]==[visible]
    assert '不应发送的私人标签' not in json.dumps(provider,ensure_ascii=False)
