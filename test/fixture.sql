CREATE DATABASE isfdb;
USE isfdb;
-- Subset of the ISFDB 2025-11-15 dump: its DDL with columns and keys trimmed, made-up rows.
-- The dump holds zero and partial dates; strict sql_mode rejects them, so this session drops it like the real import.
SET NAMES utf8mb4;
SET SESSION sql_mode = 'NO_ENGINE_SUBSTITUTION';

CREATE TABLE `pubs` (
  `pub_id` int NOT NULL AUTO_INCREMENT,
  `pub_title` mediumtext,
  `pub_tag` varchar(32) DEFAULT NULL,
  `pub_year` date DEFAULT NULL,
  `pub_ctype` enum('ANTHOLOGY','COLLECTION','MAGAZINE','NONFICTION','NOVEL','OMNIBUS','FANZINE','CHAPBOOK') DEFAULT NULL,
  `pub_isbn` varchar(100) DEFAULT NULL,
  PRIMARY KEY (`pub_id`),
  KEY `tagindex` (`pub_tag`(10)),
  KEY `isbn` (`pub_isbn`),
  KEY `pub_date` (`pub_year`) USING BTREE
) ENGINE=MyISAM DEFAULT CHARSET=latin1;

CREATE TABLE `titles` (
  `title_id` int NOT NULL AUTO_INCREMENT,
  `title_title` mediumtext,
  `title_copyright` date DEFAULT NULL,
  `title_ttype` enum('ANTHOLOGY','BACKCOVERART','COLLECTION','COVERART','INTERIORART','EDITOR','ESSAY','INTERVIEW','NOVEL','NONFICTION','OMNIBUS','POEM','REVIEW','SERIAL','SHORTFICTION','CHAPBOOK') DEFAULT NULL,
  PRIMARY KEY (`title_id`),
  KEY `title_date` (`title_copyright`) USING BTREE,
  FULLTEXT KEY `full_text` (`title_title`)
) ENGINE=MyISAM DEFAULT CHARSET=latin1;

CREATE TABLE `authors` (
  `author_id` int NOT NULL AUTO_INCREMENT,
  `author_canonical` mediumtext,
  `author_birthdate` date DEFAULT NULL,
  `author_deathdate` date DEFAULT NULL,
  PRIMARY KEY (`author_id`),
  KEY `canonical` (`author_canonical`(50))
) ENGINE=MyISAM DEFAULT CHARSET=latin1;

CREATE TABLE `submissions` (
  `sub_id` int NOT NULL AUTO_INCREMENT,
  `sub_state` enum('N','R','I','P') DEFAULT NULL,
  `sub_data` mediumtext,
  `sub_time` datetime DEFAULT NULL,
  `sub_reviewed` datetime DEFAULT NULL,
  `sub_submitter` int NOT NULL DEFAULT '0',
  PRIMARY KEY (`sub_id`)
) ENGINE=MyISAM DEFAULT CHARSET=latin1;

CREATE TABLE `mw_user_groups` (
  `ug_user` int unsigned NOT NULL DEFAULT '0',
  `ug_group` varbinary(255) NOT NULL DEFAULT '',
  `ug_expiry` varbinary(14) DEFAULT NULL,
  PRIMARY KEY (`ug_user`,`ug_group`),
  KEY `ug_group` (`ug_group`),
  KEY `ug_expiry` (`ug_expiry`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

INSERT INTO `pubs` (`pub_id`, `pub_title`, `pub_tag`, `pub_year`, `pub_ctype`, `pub_isbn`) VALUES
  (1, 'Dune', 'DNTRVLBKPV0000', '0000-00-00', 'NOVEL', '9780441013593'),
  (2, 'Krieger im Schatten', 'KRGRMSCHTT2016', '2016-11-00', 'NOVEL', '9783453317703'),
  (3, 'Foundation', 'FNDTNXXXXX1990', '1990-00-00', 'NOVEL', NULL),
  (4, 'Hyperion', 'HYPRNXXXXX1990', '1990-05-00', 'NOVEL', NULL),
  (5, 'Neuromancer', 'NRMNCRXXXX1984', '1984-07-01', 'NOVEL', NULL),
  (6, 'Die Stadt und die Sterne: Über', 'DSTDTNDDST0000', NULL, 'NOVEL', NULL);

INSERT INTO `titles` (`title_id`, `title_title`, `title_copyright`, `title_ttype`) VALUES
  (1, 'Dune', '1965-00-00', 'NOVEL'),
  (2, 'Dune Messiah', '1969-10-15', 'NOVEL'),
  (3, 'Krieger im Schatten', '2016-00-00', 'NOVEL'),
  (4, 'Hyperion', '0000-00-00', 'NOVEL'),
  (5, 'Die Stadt und die Sterne: Über', NULL, 'NOVEL');

INSERT INTO `authors` (`author_id`, `author_canonical`, `author_birthdate`, `author_deathdate`) VALUES
  (1, 'Frank Herbert', '1920-10-08', '1986-02-11'),
  (2, 'Unknown Pulp Writer', '1901-00-00', '0000-00-00'),
  (3, 'Anonymous', NULL, NULL);

INSERT INTO `submissions` (`sub_id`, `sub_state`, `sub_data`, `sub_time`, `sub_reviewed`, `sub_submitter`) VALUES
  (1, 'I', '<NewPub/>', '0000-00-00 00:00:00', NULL, 1),
  (2, 'I', '<EditPub/>', '2025-11-15 10:20:30', '2025-11-15 11:00:00', 1);

INSERT INTO `mw_user_groups` (`ug_user`, `ug_group`, `ug_expiry`) VALUES
  (1, 'sysop', NULL),
  (2, 'bureaucrat', NULL);
