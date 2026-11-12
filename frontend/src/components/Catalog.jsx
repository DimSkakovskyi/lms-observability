import CourseCard from "./CourseCard";

export default function Catalog({
  isAdmin,
  search,
  onSearchChange,
  courses,
  enrollmentByCourse,
  busyId,
  onEnroll,
  onProgress,
  onEdit,
  onTogglePublished,
  onDelete,
}) {
  return (
    <section className="catalog" id="catalog">
      <div className="catalog-heading">
        <div>
          <p className="eyebrow">Каталог</p>
          <h2>{isAdmin ? "Усі курси" : "Оберіть курс"}</h2>
        </div>
        <input
          className="search"
          value={search}
          onChange={(event) => onSearchChange(event.target.value)}
          placeholder="Пошук курсу…"
          aria-label="Пошук курсу"
        />
      </div>

      {courses.length === 0 ? (
        <div className="empty-state">
          <strong>Курсів не знайдено</strong>
          <span>Змініть пошуковий запит або додайте новий курс.</span>
        </div>
      ) : (
        <div className="course-grid">
          {courses.map((course) => (
            <CourseCard
              key={course.id}
              course={course}
              enrollment={enrollmentByCourse[course.id]}
              isAdmin={isAdmin}
              onEnroll={onEnroll}
              onProgress={onProgress}
              onEdit={onEdit}
              onTogglePublished={onTogglePublished}
              onDelete={onDelete}
              busy={busyId === course.id}
            />
          ))}
        </div>
      )}
    </section>
  );
}
