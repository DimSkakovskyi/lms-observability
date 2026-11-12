export default function CourseCard({
  course,
  enrollment,
  isAdmin,
  onEnroll,
  onProgress,
  onEdit,
  onTogglePublished,
  onDelete,
  busy,
}) {
  return (
    <article className={`course-card ${course.published ? "" : "is-unpublished"}`}>
      <div className="course-topline">
        <div className="course-tags">
          <span className="course-tag">{course.duration_hours} год</span>
          {isAdmin && (
            <span className={course.published ? "status-published" : "status-hidden"}>
              {course.published ? "Опубліковано" : "Приховано"}
            </span>
          )}
        </div>
        <span className="course-id">#{String(course.id).padStart(2, "0")}</span>
      </div>
      <h3>{course.title}</h3>
      <p>{course.description}</p>
      <div className="course-footer">
        <div>
          <span className="caption">Викладач</span>
          <strong>{course.instructor}</strong>
        </div>
        {!course.published ? (
          <span className="hidden-badge">Недоступно студентам</span>
        ) : !enrollment ? (
          <button type="button" onClick={() => onEnroll(course.id)} disabled={busy}>
            Записатися
          </button>
        ) : (
          <span className="enrolled-badge">Записано</span>
        )}
      </div>

      {enrollment && course.published && (
        <div className="progress-block">
          <div className="progress-label">
            <span>Прогрес</span><strong>{enrollment.progress_percent}%</strong>
          </div>
          <div className="progress-track">
            <span style={{ width: `${enrollment.progress_percent}%` }} />
          </div>
          {enrollment.progress_percent < 100 && (
            <button
              className="progress-button"
              type="button"
              onClick={() => onProgress(enrollment)}
              disabled={busy}
            >
              +25% прогресу
            </button>
          )}
        </div>
      )}

      {isAdmin && (
        <div className="admin-card-actions">
          <button className="secondary-button" type="button" onClick={() => onEdit(course)} disabled={busy}>
            Редагувати
          </button>
          <button className="visibility-button" type="button" onClick={() => onTogglePublished(course)} disabled={busy}>
            {course.published ? "Приховати" : "Опублікувати"}
          </button>
          <button className="danger-button" type="button" onClick={() => onDelete(course)} disabled={busy}>
            Видалити
          </button>
        </div>
      )}
    </article>
  );
}
