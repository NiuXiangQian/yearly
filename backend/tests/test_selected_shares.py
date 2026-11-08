"""Exact selected-media scope; synthetic originals and FakeStorage only."""
import pytest
from sqlalchemy import select
from app.models import Media, TimelineShare, TimelineFolder, TimelineDay
from conftest import upload, file_payload
from test_folders import folder


def selected(context, ids):
    response = context.client.post('/api/shares', json={'media_ids': ids, 'hours': 24})
    assert response.status_code == 200, response.text
    return response.json()


def items(context, share):
    response = context.client.get('/api/public/shares/' + share['token'])
    assert response.status_code == 200, response.text
    return [item for day in response.json()['days'] for item in day['items']]


def test_selected_share_excludes_date_and_folder_siblings_and_keeps_live_pair(context):
    f = folder(context)
    a = upload(context)['media_id']
    unselected = upload(context)['media_id']
    live = upload(context, content=b'synthetic-live', media_type='live_photo', files=[
        file_payload(b'synthetic-live', 'a.heic'), file_payload(b'synthetic-live', 'a.mov', 'live_video')
    ])['media_id']
    context.client.post('/api/folders/move-media', json={'folder_id': f['id'], 'media_ids': [a, unselected]})
    s = selected(context, [live, a, live])
    assert s['scope'] == 'selection' and s['selected_count'] == 2
    assert [x['id'] for x in items(context, s)] == [live, a]
    assert all(x['kind'] == 'media' for x in items(context, s))
    base = '/api/public/shares/' + s['token']
    assert context.client.get(f'{base}/media/{unselected}/url').status_code == 404
    assert context.client.get(f'{base}/folders/{f["id"]}').status_code == 404
    assert context.client.get(f'{base}/media/{a}/url?purpose=original').status_code == 422
    assert context.client.get(f'{base}/media/{live}/url').status_code == 200
    motion = context.client.get(f'{base}/media/{live}/url?live=true')
    assert motion.status_code == 200 and motion.json()['status'] == 'pending'
    upload(context)  # same-day additions never broaden an exact selection
    assert [x['id'] for x in items(context, s)] == [live, a]
    history = context.client.get('/api/shares').json()[0]
    assert history['scope'] == 'selection' and 'token' not in history and 'media_ids' not in history
    assert context.client.delete(f'/api/shares/{s["id"]}').status_code == 200
    assert context.client.get(f'{base}/media/{a}/url').status_code == 404


def test_unknown_date_and_changed_date_stay_selected_but_permissions_still_apply(context):
    a = upload(context, taken=None)['media_id']
    s = selected(context, [a])
    assert [x['id'] for x in items(context, s)] == [a]
    with context.db() as db:
        media = db.get(Media, a)
        from datetime import date
        media.timeline_date = date(2020, 1, 2)
        db.commit()
    assert [x['id'] for x in items(context, s)] == [a]
    context.client.put('/api/timeline/days/2020-01-02/sharing', json={'share_allowed': False})
    assert items(context, s) == []
    assert context.client.get(f'/api/public/shares/{s["token"]}/media/{a}/url').status_code == 404


@pytest.mark.parametrize('reason', ['hidden', 'deleted', 'uploading', 'avatar', 'hidden-folder', 'hidden-day', 'missing'])
def test_cannot_create_selected_share_with_unshareable_media(context, reason):
    a = upload(context)['media_id']
    if reason == 'missing':
        a = 99999999
    else:
        with context.db() as db:
            media = db.get(Media, a)
            if reason == 'hidden': media.share_allowed = False
            if reason in ('deleted', 'uploading'): media.status = reason
            if reason == 'avatar': media.purpose = 'avatar'
            if reason == 'hidden-day':
                from datetime import date
                db.add(TimelineDay(timeline_date=date(2024, 3, 31), share_allowed=False))
            if reason == 'hidden-folder':
                from datetime import date
                parent = TimelineFolder(name='private', timeline_date=date(2024, 3, 31), share_allowed=False)
                db.add(parent); db.flush(); media.folder_id = parent.id
            db.commit()
    response = context.client.post('/api/shares', json={'media_ids': [a]})
    assert response.status_code == 422
    with context.db() as db:
        assert db.scalar(select(TimelineShare.id)) is None


@pytest.mark.parametrize('payload', [
    {'media_ids': []}, {'media_ids': [0]}, {'media_ids': [-1]}, {'media_ids': [1.5]},
    {'media_ids': ['1']}, {'media_ids': list(range(1, 202))},
    {'media_ids': [1], 'start_date': '2024-03-31', 'end_date': '2024-03-31'},
    {'media_ids': None},
])
def test_selection_validation_is_closed_not_date_fallback(context, payload):
    assert context.client.post('/api/shares', json=payload).status_code == 422


def test_selection_requires_editor_and_csrf(context):
    a = upload(context)['media_id']
    context.client.cookies.set('yearly_session', 'viewer')
    context.client.headers['X-CSRF-Token'] = 'csrf-viewer'
    assert context.client.post('/api/shares', json={'media_ids': [a]}).status_code == 403
    context.client.cookies.set('yearly_session', 'member')
    assert context.client.post('/api/shares', json={'media_ids': [a]}).status_code == 403
    context.client.cookies.clear()
    assert context.client.post('/api/shares', json={'media_ids': [a]}).status_code == 401
