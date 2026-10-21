;;; iuiw-mybatis-test.el --- MyBatis jump checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'nxml-mode)
(require 'iuiw-mybatis)

(defmacro iuiw-mybatis-test--with-repo (&rest body)
  "Run BODY in a temporary git-like repo holding a mapper and its XML."
  (declare (indent 0))
  `(let ((root (file-name-as-directory (make-temp-file "iuiw-mybatis" t))))
     (unwind-protect
         (progn
           (make-directory (expand-file-name ".git" root))
           (iuiw-mybatis-test--write root "src/main/java/a/b/FooMapper.java"
                                    "package a.b;

public interface FooMapper {
    Foo selectFoo(@Param(\"id\") Long id);

    int insertFoo(Foo foo);
}
")
           (iuiw-mybatis-test--write root "src/main/java/c/FooMapper.java"
                                    "package c;

public interface FooMapper {
    Foo selectFoo(Long id);
}
")
           (iuiw-mybatis-test--write root "src/main/resources/mapper/FooMapper.xml"
                                    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<mapper namespace=\"a.b.FooMapper\">
    <sql id=\"cols\">id, name</sql>

    <select id=\"selectFoo\" resultType=\"Foo\">
        select <include refid=\"cols\"/>
        from foo
    </select>

    <insert
        parameterType=\"Foo\"
        id=\"insertFoo\">
        insert into foo values (#{id})
    </insert>
</mapper>
")
           ,@body)
       (delete-directory root t))))

(defun iuiw-mybatis-test--write (root path text)
  "Write TEXT to PATH under ROOT, creating folders."
  (let ((file (expand-file-name path root)))
    (make-directory (file-name-directory file) t)
    (write-region text nil file nil 'silent)))

(defun iuiw-mybatis-test--target (root path search mode)
  "Visit PATH under ROOT in MODE with point on SEARCH; return the target line."
  (with-temp-buffer
    (insert-file-contents (expand-file-name path root))
    (setq buffer-file-name (expand-file-name path root)
          default-directory (file-name-directory buffer-file-name))
    (funcall mode)
    (goto-char (point-min))
    (search-forward search)
    (backward-char)
    (when-let* ((target (if (derived-mode-p 'nxml-mode)
                            (iuiw-mybatis--xml-target)
                          (iuiw-mybatis--java-target))))
      (with-temp-buffer
        (insert-file-contents (car target))
        (goto-char (cdr target))
        (cons (file-relative-name (car target) root)
              (string-trim (buffer-substring (point) (line-end-position))))))))

(ert-deftest iuiw-mybatis-java-to-xml ()
  (iuiw-mybatis-test--with-repo
    (should (equal (iuiw-mybatis-test--target
                    root "src/main/java/a/b/FooMapper.java" "selectFoo" #'fundamental-mode)
                   '("src/main/resources/mapper/FooMapper.xml"
                     . "<select id=\"selectFoo\" resultType=\"Foo\">")))
    (should (equal (car (iuiw-mybatis-test--target
                         root "src/main/java/a/b/FooMapper.java" "insertFoo" #'fundamental-mode))
                   "src/main/resources/mapper/FooMapper.xml"))))

(ert-deftest iuiw-mybatis-java-falls-back ()
  (iuiw-mybatis-test--with-repo
    (should-not (iuiw-mybatis-test--target
                 root "src/main/java/a/b/FooMapper.java" "Long" #'fundamental-mode))
    (should-not (iuiw-mybatis-test--target
                 root "src/main/java/c/FooMapper.java" "selectFoo" #'fundamental-mode))))

(ert-deftest iuiw-mybatis-xml-to-java ()
  (iuiw-mybatis-test--with-repo
    (should (equal (iuiw-mybatis-test--target
                    root "src/main/resources/mapper/FooMapper.xml" "from foo" #'nxml-mode)
                   '("src/main/java/a/b/FooMapper.java"
                     . "selectFoo(@Param(\"id\") Long id);")))
    (should (equal (iuiw-mybatis-test--target
                    root "src/main/resources/mapper/FooMapper.xml" "values" #'nxml-mode)
                   '("src/main/java/a/b/FooMapper.java" . "insertFoo(Foo foo);")))
    (should (equal (iuiw-mybatis-test--target
                    root "src/main/resources/mapper/FooMapper.xml" "namespace" #'nxml-mode)
                   '("src/main/java/a/b/FooMapper.java" . "FooMapper {")))))

;;; iuiw-mybatis-test.el ends here
