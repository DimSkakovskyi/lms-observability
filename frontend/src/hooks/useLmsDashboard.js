import { useCallback, useEffect, useMemo, useState } from "react";

import { request } from "../api/client";

export default function useLmsDashboard({ token, onLogout }) {
  const [user, setUser] = useState(null);
  const [courses, setCourses] = useState([]);
  const [enrollments, setEnrollments] = useState([]);
  const [search, setSearch] = useState("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busyId, setBusyId] = useState(null);
  const [editorCourse, setEditorCourse] = useState(undefined);
  const [editorBusy, setEditorBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const me = await request("/api/auth/me", { token });
      const coursePath = me.role === "admin"
        ? "/api/courses?include_unpublished=true"
        : "/api/courses";
      const [courseData, enrollmentData] = await Promise.all([
        request(coursePath, { token }),
        request("/api/enrollments", { token }),
      ]);
      setUser(me);
      setCourses(courseData.items);
      setEnrollments(enrollmentData);
      setError("");
    } catch (loadError) {
      if (/401|Authentication|token/i.test(loadError.message)) onLogout();
      else setError(loadError.message);
    }
  }, [token, onLogout]);

  useEffect(() => {
    load();
  }, [load]);

  const isAdmin = user?.role === "admin";
  const enrollmentByCourse = useMemo(
    () => Object.fromEntries(enrollments.map((item) => [item.course_id, item])),
    [enrollments],
  );
  const filteredCourses = useMemo(
    () => courses.filter((course) =>
      `${course.slug} ${course.title} ${course.description} ${course.instructor}`
        .toLowerCase()
        .includes(search.toLowerCase()),
    ),
    [courses, search],
  );
  const publishedCount = courses.filter((course) => course.published).length;
  const hiddenCount = courses.length - publishedCount;
  const editorOpen = editorCourse !== undefined;

  function clearMessages() {
    setError("");
    setNotice("");
  }

  function openEditor(course = null) {
    clearMessages();
    setEditorCourse(course);
  }

  function closeEditor() {
    setEditorCourse(undefined);
  }

  async function saveCourse(payload) {
    setEditorBusy(true);
    clearMessages();
    try {
      const editing = Boolean(editorCourse?.id);
      const saved = await request(
        editing ? `/api/courses/${editorCourse.id}` : "/api/courses",
        {
          token,
          method: editing ? "PATCH" : "POST",
          body: JSON.stringify(payload),
        },
      );
      setCourses((items) => editing
        ? items.map((item) => (item.id === saved.id ? saved : item))
        : [saved, ...items]);
      closeEditor();
      setNotice(editing ? "Курс успішно оновлено." : "Новий курс додано до каталогу.");
    } catch (actionError) {
      setError(actionError.message);
    } finally {
      setEditorBusy(false);
    }
  }

  async function togglePublished(course) {
    setBusyId(course.id);
    clearMessages();
    try {
      const updated = await request(`/api/courses/${course.id}`, {
        token,
        method: "PATCH",
        body: JSON.stringify({ published: !course.published }),
      });
      setCourses((items) => items.map((item) => (item.id === updated.id ? updated : item)));
      if (editorCourse?.id === updated.id) setEditorCourse(updated);
      setNotice(updated.published
        ? `Курс «${updated.title}» знову опубліковано.`
        : `Курс «${updated.title}» приховано від студентів.`);
    } catch (actionError) {
      setError(actionError.message);
    } finally {
      setBusyId(null);
    }
  }

  async function deleteCourse(course) {
    setBusyId(course.id);
    clearMessages();
    try {
      await request(`/api/courses/${course.id}`, { token, method: "DELETE" });
      setCourses((items) => items.filter((item) => item.id !== course.id));
      if (editorCourse?.id === course.id) closeEditor();
      setNotice(`Курс «${course.title}» видалено.`);
    } catch (actionError) {
      setError(actionError.message);
    } finally {
      setBusyId(null);
    }
  }

  async function enroll(courseId) {
    setBusyId(courseId);
    clearMessages();
    try {
      const enrollment = await request("/api/enrollments", {
        token,
        method: "POST",
        body: JSON.stringify({ course_id: courseId }),
      });
      setEnrollments((items) => [enrollment, ...items]);
      setNotice("Ви успішно записалися на курс.");
    } catch (actionError) {
      setError(actionError.message);
    } finally {
      setBusyId(null);
    }
  }

  async function advanceProgress(enrollment) {
    setBusyId(enrollment.course_id);
    clearMessages();
    try {
      const updated = await request(`/api/enrollments/${enrollment.id}/progress`, {
        token,
        method: "PATCH",
        body: JSON.stringify({
          progress_percent: Math.min(100, enrollment.progress_percent + 25),
        }),
      });
      setEnrollments((items) =>
        items.map((item) => (item.id === updated.id ? updated : item)),
      );
      setNotice(updated.progress_percent === 100
        ? "Вітаємо! Курс завершено."
        : `Прогрес оновлено до ${updated.progress_percent}%.`);
    } catch (actionError) {
      setError(actionError.message);
    } finally {
      setBusyId(null);
    }
  }

  return {
    user,
    courses,
    enrollments,
    search,
    setSearch,
    error,
    notice,
    busyId,
    editorCourse,
    editorBusy,
    editorOpen,
    isAdmin,
    enrollmentByCourse,
    filteredCourses,
    publishedCount,
    hiddenCount,
    openEditor,
    closeEditor,
    saveCourse,
    togglePublished,
    deleteCourse,
    enroll,
    advanceProgress,
  };
}
