export type ReviewMedia = {
  id: number; title: string; media_type: string; timeline_day: string | null;
  taken_at_local: string | null; tags: string[]; remark: string;
  child_ids: number[];
  files: { id: number; file_role: string; mime_type: string }[];
  interview_status?: string;
};
export type ReviewFace = {
  id: number; thumbnail: string; child_id: number | null; ignored: boolean;
  frame_seconds: number | null;
  auto_assigned?: boolean; auto_match_score?: number | null;
  candidates: { child_id: number; name: string; similarity: number; reference_thumbnail: string }[];
  media: ReviewMedia;
};
export type ReviewQueue = {
  enabled: boolean; ready: boolean; message: string; items: ReviewFace[]; next_cursor: number | null;
  pending_faces: number; pending_memories: number; unanalysed_photos: number;
  auto_link_enabled?: boolean;
};
export type InterviewState = {
  media: ReviewMedia; description: string; confirmed_people: string[];
  confirmed_pets?: string[];
  identity_questions: { face_id: number; question: string }[];
  faces: ReviewFace[]; face_enabled: boolean; face_ready: boolean;
  messages: { role: "user" | "assistant"; content: string }[];
  status: "not_started" | "draft" | "completed"; outdated: boolean;
  suggestions: null | {
    question: string; options: string[]; story: string;
    tags: { name: string; source: "visual" | "answer" | "existing"; evidence: string }[];
  };
};
